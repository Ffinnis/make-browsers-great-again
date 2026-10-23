# Media converter

MBGA's engine is Chromium without proprietary codecs: Media Source
Extensions refuse H.264 and AAC, so video on X, Twitch, Bluesky, Reddit,
Instagram and Facebook doesn't play. The engine does play VP9 and FLAC in
MP4, and its WebCodecs can decode H.264 through VideoToolbox and encode VP9.
So `shell/resources/media/shim.js` sends what pages append to a SourceBuffer
to a worker (`shell/resources/media/worker.js`), which converts it with this
crate, built to WebAssembly:

- H.264 becomes VP9 (`vp09.00.41.08`). The crate demuxes the fragments and
  rewrites samples as Annex-B with SPS and PPS before each keyframe; the
  worker decodes them with a `VideoDecoder` configured without a
  description (with one, or through `isConfigSupported()`, the engine says
  H.264 is unsupported), which carries on from one fragment to the next,
  and encodes the frames it puts out with a `VideoEncoder`: a VP9 keyframe
  wherever the input has an IDR picture, at the size the shim asks for
  (never larger than the input's), at the input's bitrate, and at most at
  the frame rate the shim caps it to.
- AAC becomes FLAC, decoded with symphonia (MPL-2.0) and written by a
  small FLAC encoder here: one FLAC frame per AAC frame, so timestamps and
  durations stay as they were. HE-AAC plays its AAC-LC core at half the
  sample rate (and HE-AACv2 in mono); the FLAC header says so.
- Other tracks pass through untouched.

Fragments keep the input's track IDs, timescales and timestamps, and the
init segment keeps everything but the sample entries, edit lists included,
so the engine lays the converted media on the same timeline as it would the
original: `buffered`, `timestampOffset`, `remove()` and A/V sync work as
the page expects. VP9 has no frame reordering, so each frame is decoded at
its presentation time.

### Frames that come out late

An H.264 decoder holds its last few frames until more input pushes them
out (B-frames are shown before frames decoded ahead of them). Flushing it
gets them out, but then it needs a keyframe to go on, so a fragment that
continues mid-GOP would have to decode the GOP again (up to 5× the
frames, with the short fragments low-latency players append). So the
crate tells the worker when flushing costs nothing (job flag `FLUSH`):
when the next fragment starts with a keyframe, which it knows for
progressive files, or, for MSE segments, as long as every one has (X's
do), and the frames waiting have no B-frames still to come. Otherwise the
decoder carries on, and frames it puts out while converting a later
append belong to the earlier one: they come back as `held`, which the
page appends with that earlier append's settings, before the new append's
own output. `drain` gets out what's left before the page ends the stream.

A different init (an ABR switch to another rendition) replaces the tracks.
Before it does, the decoder is flushed (a job of `FINISH` samples), so the
old stream's frames come out and are written with its timescale, sizes and
the appends they came in, then the new init. Decoding runs go on counting
across inits, so frames of the old stream and of the new one at the same
times (a replacement over what's buffered) are told apart. The same init
again changes nothing.

## Building

The toolchain in `rust-toolchain.toml` includes the WebAssembly target.

```sh
cargo build --manifest-path media/Cargo.toml --release --target wasm32-unknown-unknown
```

The module is `media/target/wasm32-unknown-unknown/release/mbga_media.wasm`,
about 310 KB (120 KB gzipped). It imports nothing; no wasm-bindgen, so the
JS glue is the few lines in worker.js.

## Worker messages

From the page (`ArrayBuffer`s are transferred):

| Message                             | Meaning                                                                                                                                                                |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `{type: 'wasm', module}`            | The module, compiled or as bytes. Earlier messages wait for it.                                                                                                        |
| `{type: 'open', sb, mime, start?}`  | A new stream on `sb`, with the type given to `addSourceBuffer()` or `changeType()`. `mime: 'progressive'` takes a whole MP4 file instead of MSE segments; `start` (seconds, progressive only) plays it from the keyframe at or before then (see Progressive files). |
| `{type: 'append', sb, seq, bytes, offset?}` | What the page appended: any mix of init and media segments, or part of one. For a progressive file, `offset` is the byte offset in the file of `bytes`' first byte (see Progressive files). |
| `{type: 'drain', sb, seq}`          | Put out every frame the decoder still holds. `seq` counts on from the appends'. Send it before `endOfStream()` and before `open` for a `changeType()`.                 |
| `{type: 'size', sb, width, height, fps?}` | Encode `sb`'s video at most this big and at most `fps` frames a second (0 or absent: all). The shim decides the size: the element's device pixels, CSS pixels on battery, the input's size for an element the video sizes; the worker obeys. Any time, as often as it changes; it applies from the next frame decoded (aspect kept, never above the input; a size that differs by more than 25% makes that frame a keyframe with an init of its own, a frame rate that differs by more than 10% changes the encoder's rate control without one). |
| `{type: 'keepalive', sb}`           | `sb` isn't idle (a progressive download paused ahead of the playhead): its codecs stay open. No reply.                                                                  |
| `{type: 'reset', sb}`               | The page aborted: drop partial input and decoder state, keep the init.                                                                                                 |
| `{type: 'close', sb}`               | Done with `sb`.                                                                                                                                                        |

`{type: 'ready'}` comes once, when the module is compiled and an instance
of it made (the shim times startup by it). Every append and every drain
gets exactly one reply, in order: `{type: 'output', sb, seq, bytes, range?,
held?, mime?, natural?, need?}`, or `{type: 'error', sb, seq, message}` when
the input can't be converted.

Times below (`range`, `held`'s `start` and `end`, `natural.at`) are in
seconds on the stream's own timeline: the input's presentation times after
the init's first edit-list offset, as the engine reads them, before the
page's `timestampOffset`. The shim adds the `timestampOffset` of the append
they belong to.

- `bytes` is the append's converted output: empty while nothing is
  complete. The converted init comes with the append that held the
  original, and again before the first output after a `reset`, in case
  the page dropped the aborted append's output with the init in it.
- `range`, `{start, end}`: the times the media in `bytes` covers (every
  track's), so the shim can drop output it holds back if the page
  `remove()`s those times first. Absent when `bytes` is empty or only an
  init.
- `held`, when there is one, is an array of groups `{seq, bytes, start,
  end}`, in append order: frames of earlier appends that the decoder put
  out only now, each group from the append numbered `seq`. Append each
  first, with the settings (`timestampOffset`, append window, mode) append
  `seq` had, then `bytes` with the current ones. `start` and `end` are the
  group's presentation times in seconds on the stream's own timeline
  (after the init's edit list, as the engine reads it, before
  `timestampOffset`), so the shim can drop a group that overlaps what the
  page `remove()`d since. A group may begin with the converted init, when
  it has to come again. A drain's reply has everything in `held` and
  `bytes` empty, so settings changed since the last append don't apply to
  it. A drain isn't needed when settings change: `held` takes care of that.
- `natural`, `{width, height, at?, seq?}`: the input video's display size,
  which the engine reports for the encoded size, smaller when the element
  is (see Limitations), so the shim shows this as `videoWidth` and
  `videoHeight` instead. It's worked out as the engine's MP4 parser and
  decoder would: the decoded picture's visible size (an avc3 stream's SPS
  can change it at any keyframe), stretched by the sample entry's pasp, or
  else to its track header's aspect. The first of a stream comes with its
  first converted init, before any frame, without `at`: it applies at once
  (pages read it at `loadedmetadata`). After that one comes whenever the
  size changes (an init with another size, an SPS), with `at`, where the
  first frame at the new size is shown, which may be long after the reply
  (a player converts ahead): the shim switches when playback gets there.
  `seq` is the append that frame came in (a `held` group's), when it isn't
  the one replied to; `at` is on its timeline. At most one per reply, the
  latest. After a `reset` or a failed append, the page may have lost the
  last one: it comes again with the next frame, without `at`.
- `need`, for a progressive file: the byte offset of the file the
  converter needs next, when it isn't the byte after the last append's
  (see Progressive files).
- `mime`, on an output whose converted init has a new type, such as
  `video/mp4; codecs="vp09.00.41.08,flac"`: progressive files need it to
  make their SourceBuffer. The page's codecs map as `avc1.*`/`avc3.*` →
  `vp09.00.41.08` and AAC `mp4a.*` → `flac`; MP3 in MP4 (`mp4a.69`,
  `mp4a.6B`, `mp4a.40.34`) isn't converted and fails.

`{type: 'fatal', message}` comes once if the module can't be compiled;
every append and drain then gets an `error`. For the harness only, the
worker answers `{type: 'stats'}` with counters and takes `{type: 'tune',
tune}` to change its settings (see worker.js).

A video-only SourceBuffer's type maps as before, `avc1`/`avc3` →
`video/mp4; codecs="vp09.00.41.08"`; VP8 in WebM was measured and isn't
worth it (see Cost).

### Progressive files

Every `append` of a progressive file says where its bytes start in the
file (`offset`). The converter takes an append only if it starts where
the last one ended or, after a reply with `need`, exactly at `need`; any
other (sent before the shim heard of `need`) is dropped, and its reply
is empty. Once a reply has `need`, the shim stops its download and goes on
from `need` (`Range: bytes=need-`, or from 0 skipping what comes before it
if the server ignores ranges). `need` comes:

- when the moov comes after an mdat (or another box) of which more than
  1 MB is still to come: `need` is where the box ends, the next box's
  start; smaller files just stream through;
- once the moov is read, if the first samples to go out aren't where the
  input is: from the moov at the end back to the samples, or past
  samples before `start`.

With `start`, samples before the video keyframe shown at or before it are
never read nor decoded (audio starts with the frame playing then, and one
before, which an AAC decoder needs); fragments keep the file's own times,
so the output lies where it would have from the start. Without `offset`
(the harness), input runs on from the file's first byte and bytes before
those needed are dropped as they come. Bytes skipped never count towards
the 192 MB of input waiting.

A progressive file that turns out to be fragmented (X's fallback MP4s are)
is read as MSE segments. Otherwise the moov's sample tables become an init
with `mvex`, and fragments of about two seconds (at a video keyframe if one
comes within a second after that), each output as soon as its bytes have
arrived. Only video and audio go in: H.264 and AAC converted, Opus and FLAC
as they are. Timecode, metadata and text tracks (iPhone movies have them)
and audio that can't be converted are left out; video that can't be
converted fails the file.

## Module API

Exports a C ABI (`src/ffi.rs`, the crate's only `unsafe`). Pointers index the
module's memory; results stay valid until the next call, which may grow the
memory, so JS copies them out first. JS writes input and chunks straight
into buffers the converter reserves, so nothing is copied twice.

| Export                                                             | Does                                                                                                |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `mm_create(progressive) → h`, `mm_destroy(h)`                      | A converter per SourceBuffer.                                                                       |
| `mm_start(h, seconds)`                                             | Where a progressive file starts playing, before any input.                                          |
| `mm_offset(h, offset) → 0 / 1`                                     | The next progressive append starts at this byte: 1 take it, 0 drop it (see Progressive files).      |
| `mm_need(h) → offset / -1`                                         | The byte the file needs next, if it isn't the next one (`need`).                                    |
| `mm_begin(h, seq)`                                                 | Starts an append or a drain, the page's `seq`: frames of earlier ones go in `held` from now on.     |
| `mm_reserve(h, len) → ptr`, `mm_commit(h, len)`                    | Room for input (null past 192 MB waiting), then takes what JS wrote there.                          |
| `mm_poll(h) → 0 / 1 / -1`                                          | Converts what's complete: 0 done, 1 a video job waits, -1 failed (`mm_error_ptr/len`).              |
| `mm_job_len(h)`, `mm_job_samples(h)`, `mm_job_data(h)`             | The job: `JobSample` records (40 bytes) and the Annex-B data their offsets point into.              |
| `mm_frame(h, track, timestamp, skip, width, height) → 0 / 1 / 2`   | The decoder put this frame out, with this visible size (0: unknown): 1 encode, 2 encode as a keyframe, 0 drop. `skip` asks to leave it out for the frame-rate cap: the frame before then lasts longer (not for keyframes, nor without one to stretch: then 1). |
| `mm_chunk_buffer(h, len) → ptr`                                    | Room for an encoded chunk.                                                                          |
| `mm_chunk(h, track, timestamp, key, width, height, len)`           | The VP9 chunk written there, its frame's timestamp and its coded size (a new size gets a new init). |
| `mm_flushed(h, track)`                                             | The decoder was flushed and all chunks are in; the next job starts at a keyframe or replays.        |
| `mm_restart(h)`                                                    | The codecs were lost (an error, or the engine reclaimed them).                                      |
| `mm_write(h)`                                                      | Ends the job, if any, and writes fragments with every chunk so far; poll again.                     |
| `mm_output_ptr/len(h)`, `mm_held_ptr/len(h)`, `mm_output_clear(h)` | Converted bytes so far, and frames of earlier appends.                                              |
| `mm_held_count(h)`, `mm_held_groups(h)`                            | `held`'s groups: `HeldGroup` records (32 bytes).                                                    |
| `mm_output_discard(h)`                                             | Drops a failed append's output; the converted init comes again before the next.                    |
| `mm_output_start/end(h)`                                           | The output's time range (`range`), NaN without media.                                               |
| `mm_inits(h)`, `mm_natural_width/height/at/seq(h)`                 | Converted inits in the output and `held`; a change of the input's display size in them (`natural`; width 0: none, `at` NaN: at once). |
| `mm_reset(h)`                                                      | After `abort()`.                                                                                    |
| `mm_recyclable(h) → 0 / 1`                                         | A fresh instance primed with the init and this one's state would carry on the same.                 |
| `mm_save_state(h) → len`, `mm_state_ptr(h)`                        | That state: where each track is, the GOP it may replay, the counters.                               |
| `mm_state_buffer(h, len) → ptr`, `mm_load_state(h, len) → 0 / -1`  | A fresh instance takes it over, after the init.                                                     |
| `mm_mime_ptr/len(h)`                                               | The converted init's type.                                                                          |
| `mm_init_ptr/len(h)`, `mm_init_generation(h)`                      | The last input init, to prime a new instance with.                                                  |

`JobSample` (little-endian): `track u32, flags u32, offset u32, len u32,
timestamp f64 (µs), duration f64 (µs), codec u32 (profile, constraints and
level for "avc1.PPCCLL"), bitrate u32 (the input's so far)`. Flags: 1 key
(an IDR picture), 2 decode only (after a flush, a fragment that continues
mid-GOP replays the GOP so far, since the decoder needs a keyframe), 4
flush the decoder after this job, 8 finish: no data, only flush (a
different init is next). `HeldGroup`: `seq f64, start f64, end f64
(seconds), offset u32, len u32` (into `held`).

The worker runs a module instance per SourceBuffer, so a trap on bad input
costs one stream one append. An instance whose memory grew past 64 MB is
replaced at the next moment nothing waits in it (WebAssembly memory never
shrinks): a fresh one is primed with the init and takes over the old one's
state, GOP included, so a fragment that continues mid-GOP after a flush
still replays it. An AAC decoder's overlap can't move, so a stream with
AAC is replaced only before its first frame or right after a reset.

A stream that gets nothing (not even a `keepalive`) for 20 seconds (a
paused, hidden or finished player) flushes its codecs and closes them, since a VP9 encoder holds tens
of MB; their last frames go out with the next reply, in `held`, and the
next append opens new ones (replaying the GOP if it continues one).

With a frame-rate cap, the worker keeps at most one frame in each `1/fps`
slot of a grid that starts at a keyframe (24 fps capped at 15 keeps 2 of
3 frames, then 1 of 2, a steady 15 fps; a frame counts as in a slot from
half a frame before it). Keyframes are always kept, and a frame is left
out for a keyframe later in its slot; the grid starts over where the
timeline jumps or the cap changes. The frame before one left out lasts
until the next kept, so the timeline has no holes and A/V stays aligned.

The worker feeds the decoder only while the decoder and encoder each have
at most 4 requests queued, so decoded frames (3 MB each at 1080p) don't
pile up, and every codec wait times out after 20 seconds with an `error`.

## Cost

Profiled with `sample` in a test copy (CEF's symbols are on Spotify's CDN,
`…_release_symbols.tar.bz2`), converting Tears of Steel 720p30 H.264 shown
at its own size: libvpx's VP9 encoder takes 98% of the renderer's time
(its row threads 70%, `vpx_codec_encode` 27%), this module and worker.js
about 1%, and mapping VideoToolbox's frames for the encoder doesn't show.
The engine encodes VP9 at speed 7 (`cpu_used` is fixed in
`vpx_video_encoder.cc`; no WebCodecs option changes it). So the cost per
frame is libvpx's, and what helps is giving it fewer pixels or frames.
CPU seconds (renderer + GPU process) per 60 s of 720p converted, M1 Max:

| Encode                                      | CPU-s | Notes                                         |
| ------------------------------------------- | ----- | --------------------------------------------- |
| VP9, 1280×720, 30 fps (as before)           | 21    | VideoToolbox decoding is 2.3 of it            |
| `latencyMode: 'quality'`                    | 21    | Same speed; no frame dropping                 |
| `bitrateMode: 'constant'`                   | 19–21 | −0.2 dB PSNR; within noise, not taken         |
| `scalabilityMode: 'L1T2'`                   | 21    | Twice the bytes                               |
| Half the bitrate                            | 19    | Less quality for 8%                           |
| VP8 (WebM needed)                           | 14    | Decoding it takes 2.2 more than VP9 (in hardware); 17% less overall, not taken |
| AV1 (libaom, realtime, 1.5 Mbps)            | 20–21 | The same as VP9 at its bitrate (it undershoots, 1.27 Mbps); but decoding it is software (dav1d): 4.9 CPU-s per 60 s against VP9's 0.5 in hardware; not taken |
| Cap at 15 fps                               | 12    | Bitrate scaled with the frame rate            |
| Cap at 5 fps (hidden)                       | 5     |                                               |
| 640×360 (element half the size)             | 7     |                                               |
| 640×360, 15 fps                             | 4.5   |                                               |

1080p: 43. Playing the VP9 the converter puts out costs 3.7 more (decoded
by VideoToolbox), the same as a native VP9 stream.

## Tests

```sh
cargo test --manifest-path media/Cargo.toml
```

The fixtures in `tests/fixtures` are synthetic (`make.sh` remakes them, on a
Mac). The tests stand in for the worker with a fake decoder that holds
frames back the way H.264 decoders do and fake VP9 chunks, and where
ffmpeg is installed check the output with it: every packet's timestamp
matches the input's, decode order never goes back, and the FLAC decodes to
the same samples as the AAC. Hostile input (sample counts in the billions,
offsets near 2^64, boxes nested without end) is built in the tests and has
to fail quickly.
Real site media can't go in the repository; set `MBGA_MEDIA_SAMPLES` to a
folder with X's segments (`vinit.mp4`, `v0.m4s`…, `ainit.mp4`, `a0.m4s`…)
and files (`v.mp4`, `gif.mp4`) to run those too.

`harness/` checks the whole path in the engine: it runs each case in
`harness/cases.json` through worker.js, appends the output to a real
MediaSource the way shim.js does (`held` first, a `drain` at the end) and
checks the buffered ranges against the input's timeline, that frames and
audio decode, A/V start alignment, and that every reply with media says
what times it covers (`range`). Progressive files go in appends that say
where they start, and on from `need` when a reply has it (and the append
already sent then has to be dropped). Cases can also abort an append,
damage the input (and expect an `error`), send `size` messages (with a
frame-rate cap), wait (with `keepalive`s) or drain between appends, append
a file's fragments in any order (`units`, to append one again), start a
progressive file later (`start`), check the `natural` sizes and where they
apply, and how many `need`s came, run with other worker settings (`tune`,
such as a 1-byte memory limit to recycle at every chance) and expect worker
counters to move (at least so far, or within `[least, most]`). The
`cadence-*` and `moov-last*` cases need sources made with ffmpeg in the
samples folder (`rateN.mp4`: `testsrc2` at 640×360 and N fps for 4 s, a
keyframe a second, fragmented; `big-last.mp4`: 30 s of 720p30 with AAC,
moov last).

```sh
python3 media/harness/expect.py <samples> /tmp/mbga-media-harness
python3 media/harness/serve.py <samples> /tmp/mbga-media-harness 8791
# then open http://127.0.0.1:8791/media/harness/index.html
# (?case=a,b runs some; ?save=1 writes each output there for ffprobe;
# ?repeat=3 runs them again, for timing; ?tune={"factor":2} tries encoder
# settings, see worker.js)
```

A tab that has never been visible defers loading media, so in a background
tab nothing past the conversion happens until it's shown; `mbga screenshot`
counts. A hidden tab also pauses muted media, so the harness seeks instead of
playing. Results are in `window.results`.

On an M1 Max, a 3-second 720×1280 segment from X converts in about 250 ms
(median over 15, at the input's bitrate; 275 ms at twice it), most of it
VP9 encoding; shown at half size, in about 170 ms; a 320×568 one in
120–200 ms, and 3 seconds of AAC in about 15 ms. Encoding X's 720p at the
input's bitrate (570 kbps) scores 40.8 dB PSNR against the decoded input
(35.9 at worst); twice that, 42.0 dB for 10% more time; the encoder's
quantizer mode at q48, 42.6 dB at 3.6 times the size and 20% more time.

## Limitations

- AAC with more than two channels, or with a program config element, isn't
  decoded (symphonia's decoder doesn't), nor is AAC with 960-sample frames.
- HE-AAC loses its top octave: only the core is decoded.
- Encrypted (EME) streams aren't converted.
- A keyframe is one with an IDR picture, which is what the engine's decoder
  starts from. After a seek, frames before the next IDR are dropped, as the
  engine itself would. After a flush (a drain, or lost codecs), a fragment
  that continues mid-GOP replays its GOP from the last IDR, up to 1,200
  frames or 32 MB back, past which it's dropped too; and B-frames shown
  before a frame the drain already put out are dropped.
- Without a `drain`, the last few frames the decoder holds never come out.
- When the video is encoded smaller, the engine's `videoWidth` and
  `videoHeight` follow the encoded size (the aspect ratio stays): it takes
  them from the frames' size and the container's aspect ratio, which only
  ever stretches one side. VP9's render_size doesn't help: the engine's
  hardware path clamps it to the frame size (`vp9_decoder.cc`), and libvpx
  ignores it. So the shim shows `natural` instead.
- A converter takes at most 192 MB of input waiting at once (a progressive
  file that isn't interleaved, or whose moov comes after that and whose
  appends don't say where they start), a fragment at most 131,072
  samples, a track of a progressive file at most a million.
