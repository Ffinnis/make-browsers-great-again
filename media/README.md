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
  wherever the input has an IDR picture, at the size the page shows the
  video at (never larger than the input's), at the input's bitrate.
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
| `{type: 'open', sb, mime}`          | A new stream on `sb`, with the type given to `addSourceBuffer()` or `changeType()`. `mime: 'progressive'` takes a whole MP4 file instead of MSE segments.              |
| `{type: 'append', sb, seq, bytes}`  | What the page appended: any mix of init and media segments, or part of one.                                                                                            |
| `{type: 'drain', sb, seq}`          | Put out every frame the decoder still holds. `seq` counts on from the appends'. Send it before `endOfStream()` and before `open` for a `changeType()`.                 |
| `{type: 'size', sb, width, height}` | The element showing `sb` is this big, in device pixels. Any time, as often as it changes; the next keyframe is encoded to fit it (aspect kept, never above the input). |
| `{type: 'reset', sb}`               | The page aborted: drop partial input and decoder state, keep the init.                                                                                                 |
| `{type: 'close', sb}`               | Done with `sb`.                                                                                                                                                        |

Every append and every drain gets exactly one reply, in order:
`{type: 'output', sb, seq, bytes, held?, mime?}`, or `{type: 'error', sb,
seq, message}` when the input can't be converted.

- `bytes` is the append's converted output: empty while nothing is
  complete. The converted init comes with the append that held the
  original, and again before the first output after a `reset`, in case
  the page dropped the aborted append's output with the init in it.
- `held`, when there is one, holds frames of earlier appends that the
  decoder put out only now. Append it first, with the settings
  (`timestampOffset`, append window, mode) the previous append had, then
  `bytes` with the current ones. A drain's reply has everything in `held`
  and `bytes` empty, so settings changed since the last append don't apply
  to it. A drain isn't needed when settings change: `held` takes care of
  that.
- `mime`, on an output whose converted init has a new type, such as
  `video/mp4; codecs="vp09.00.41.08,flac"`: progressive files need it to
  make their SourceBuffer. The page's codecs map as `avc1.*`/`avc3.*` →
  `vp09.00.41.08` and AAC `mp4a.*` → `flac`; MP3 in MP4 (`mp4a.69`,
  `mp4a.6B`, `mp4a.40.34`) isn't converted and fails.

`{type: 'fatal', message}` comes once if the module can't be compiled;
every append and drain then gets an `error`. The worker also answers
`{type: 'stats'}` with counters for the harness.

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
| `mm_begin(h)`                                                      | Starts an append or a drain: frames of earlier ones go in `held` from now on.                       |
| `mm_reserve(h, len) → ptr`, `mm_commit(h, len)`                    | Room for input (null past 192 MB waiting), then takes what JS wrote there.                          |
| `mm_poll(h) → 0 / 1 / -1`                                          | Converts what's complete: 0 done, 1 a video job waits, -1 failed (`mm_error_ptr/len`).              |
| `mm_job_len(h)`, `mm_job_samples(h)`, `mm_job_data(h)`             | The job: `JobSample` records (40 bytes) and the Annex-B data their offsets point into.              |
| `mm_frame(h, track, timestamp) → 0 / 1`                            | The decoder put this frame out: 1 to encode it, 0 to drop it (decode order would go back).          |
| `mm_chunk_buffer(h, len) → ptr`                                    | Room for an encoded chunk.                                                                          |
| `mm_chunk(h, track, timestamp, key, width, height, len)`           | The VP9 chunk written there, its frame's timestamp and its coded size (a new size gets a new init). |
| `mm_flushed(h, track)`                                             | The decoder was flushed and all chunks are in; the next job starts at a keyframe or replays.        |
| `mm_restart(h)`                                                    | The codecs were lost (an error, or the engine reclaimed them).                                      |
| `mm_write(h)`                                                      | Ends the job, if any, and writes fragments with every chunk so far; poll again.                     |
| `mm_output_ptr/len(h)`, `mm_held_ptr/len(h)`, `mm_output_clear(h)` | Converted bytes so far, and frames of earlier appends.                                              |
| `mm_reset(h)`                                                      | After `abort()`.                                                                                    |
| `mm_recyclable(h) → 0 / 1`                                         | Nothing waits in the converter, so a fresh instance primed with the init would carry on the same.   |
| `mm_mime_ptr/len(h)`                                               | The converted init's type.                                                                          |
| `mm_init_ptr/len(h)`, `mm_init_generation(h)`                      | The last input init, to prime a new instance with.                                                  |

`JobSample` (little-endian): `track u32, flags u32, offset u32, len u32,
timestamp f64 (µs), duration f64 (µs), codec u32 (profile, constraints and
level for "avc1.PPCCLL"), bitrate u32 (the input's so far)`. Flags: 1 key
(an IDR picture), 2 decode only (after a flush, a fragment that continues
mid-GOP replays the GOP so far, since the decoder needs a keyframe), 4
flush the decoder after this job.

The worker runs a module instance per SourceBuffer, so a trap on bad input
costs one stream one append. An instance whose memory grew past 64 MB is
replaced at the next moment nothing waits in it: WebAssembly memory never
shrinks.

The worker feeds the decoder only while the decoder and encoder each have
at most 4 requests queued, so decoded frames (3 MB each at 1080p) don't
pile up, and every codec wait times out after 20 seconds with an `error`.

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
audio decode, and A/V start alignment. Cases can also abort an append,
damage the input (and expect an `error`), and send `size` messages.

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
- When the video is encoded smaller, `videoWidth` and `videoHeight` follow
  the encoded size (the aspect ratio stays): the engine takes them from the
  frames, not from the track header, which keeps the input's size.
- A converter takes at most 192 MB of input waiting at once (a progressive
  file whose moov comes after that, or that isn't interleaved), a fragment
  at most 131,072 samples, a track of a progressive file at most a million.
