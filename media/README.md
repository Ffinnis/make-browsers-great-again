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
  H.264 is unsupported), and encodes each fragment's frames with a
  `VideoEncoder`, starting on a keyframe, at twice the source bitrate.
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

## Building

The toolchain in `rust-toolchain.toml` includes the WebAssembly target.

```sh
cargo build --manifest-path media/Cargo.toml --release --target wasm32-unknown-unknown
```

The module is `media/target/wasm32-unknown-unknown/release/mbga_media.wasm`,
about 280 KB (105 KB gzipped). It imports nothing; no wasm-bindgen, so the
JS glue is the few lines in worker.js.

## Worker messages

From the page (`ArrayBuffer`s are transferred):

| Message                            | Meaning                                                                                                                                                   |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `{type: 'wasm', module}`           | The module, compiled or as bytes. Earlier messages wait for it.                                                                                           |
| `{type: 'open', sb, mime}`         | A new stream on `sb`, with the type given to `addSourceBuffer()` or `changeType()`. `mime: 'progressive'` takes a whole MP4 file instead of MSE segments. |
| `{type: 'append', sb, seq, bytes}` | What the page appended: any mix of init and media segments, or part of one.                                                                               |
| `{type: 'reset', sb}`              | The page aborted: drop partial input and decoder state, keep the init.                                                                                    |
| `{type: 'close', sb}`              | Done with `sb`.                                                                                                                                           |

Every append gets exactly one reply, in order: `{type: 'output', sb, seq,
bytes}` with the converted bytes (empty while nothing is complete; the
converted init comes with the append that held the original), or
`{type: 'error', sb, seq, message}` when the input can't be converted. An
output whose converted init has a new type also carries `mime`, such as
`video/mp4; codecs="vp09.00.41.08,flac"`: progressive files need it to make
their SourceBuffer. The page's codecs map as `avc1.*`/`avc3.*` →
`vp09.00.41.08` and AAC `mp4a.*` → `flac`; MP3 in MP4 (`mp4a.69`, `mp4a.6B`,
`mp4a.40.34`) isn't converted and fails.

A progressive file that turns out to be fragmented (X's fallback MP4s are)
is read as MSE segments. Otherwise the moov's sample tables become an init
with `mvex`, and fragments of at least two seconds cut at video keyframes,
each output as soon as its bytes have arrived.

## Module API

Exports a C ABI (`src/ffi.rs`, the crate's only `unsafe`). Pointers index the
module's memory; results stay valid until the next call, which may grow the
memory, so JS copies them out first.

| Export                                                 | Does                                                                                   |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `mm_alloc(len) → ptr`, `mm_free(ptr, len)`             | Buffers to pass bytes in.                                                              |
| `mm_create(progressive) → h`, `mm_destroy(h)`          | A converter per SourceBuffer.                                                          |
| `mm_push(h, ptr, len)`                                 | Appends input.                                                                         |
| `mm_poll(h) → 0 / 1 / -1`                              | Converts what's complete: 0 done, 1 a video job waits, -1 failed (`mm_error_ptr/len`). |
| `mm_job_len(h)`, `mm_job_samples(h)`, `mm_job_data(h)` | The job: `JobSample` records (48 bytes) and the Annex-B data their offsets point into. |
| `mm_chunk(h, track, timestamp, key, ptr, len)`         | An encoded VP9 chunk, with its frame's timestamp.                                      |
| `mm_finish(h)`                                         | Writes the job's fragment; poll again.                                                 |
| `mm_output_ptr/len(h)`, `mm_output_clear(h)`           | Converted bytes so far.                                                                |
| `mm_reset(h)`                                          | After `abort()`.                                                                       |
| `mm_mime_ptr/len(h)`                                   | The converted init's type.                                                             |
| `mm_init_ptr/len(h)`, `mm_init_generation(h)`          | The last input init, to prime a new instance with after a trap.                        |

`JobSample` (little-endian): `track u32, flags u32, offset u32, len u32,
timestamp f64 (µs), duration f64 (µs), codec u32 (profile, constraints and
level for "avc1.PPCCLL"), bitrate u32, hold_from f64 (µs)`. Flags: 1 key, 2
decode only (a fragment that starts mid-GOP replays the GOP so far, since a
flushed decoder needs a keyframe), 4 no frames held from an earlier job. A
fragment that ends mid-GOP can end on a frame whose B-frames are still to
come; frames from `hold_from` on stay decoded but unencoded until the next
job, so VP9's decode order never goes back.

The worker runs a module instance per SourceBuffer, so a trap on bad input
costs one stream one append.

## Tests

```sh
cargo test --manifest-path media/Cargo.toml
```

The fixtures in `tests/fixtures` are synthetic (`make.sh` remakes them, on a
Mac). The tests stand in for the worker with fake VP9 chunks, and where
ffmpeg is installed check the output with it: every packet's timestamp
matches the input's, and the FLAC decodes to the same samples as the AAC.
Real site media can't go in the repository; set `MBGA_MEDIA_SAMPLES` to a
folder with X's segments (`vinit.mp4`, `v0.m4s`…, `ainit.mp4`, `a0.m4s`…)
and files (`v.mp4`, `gif.mp4`) to run those too.

`harness/` checks the whole path in the engine: it runs each case in
`harness/cases.json` through worker.js, appends the output to a real
MediaSource and checks the buffered ranges against the input's timeline,
that frames and audio decode, and A/V start alignment.

```sh
python3 media/harness/expect.py <samples> /tmp/mbga-media-harness
python3 media/harness/serve.py <samples> /tmp/mbga-media-harness 8791
# then open http://127.0.0.1:8791/media/harness/index.html
# (?case=a,b runs some; ?save=1 writes each output there for ffprobe)
```

A tab that has never been visible defers loading media, so in a background
tab nothing past the conversion happens until it's shown; `mbga screenshot`
counts. A hidden tab also pauses muted media, so the harness seeks instead of
playing. Results are in `window.results`.

On an M-series Mac, a 3-second 720×1280 segment from X converts in
260–550 ms (about 310 typically), most of it VP9 encoding; a 320×568 one in
130–220 ms, and 3 seconds of AAC in about 15 ms.

## Limitations

- AAC with more than two channels, or with a program config element, isn't
  decoded (symphonia's decoder doesn't), nor is AAC with 960-sample frames.
- HE-AAC loses its top octave: only the core is decoded.
- Encrypted (EME) streams aren't converted.
- A keyframe is one with an IDR picture, which is what the engine's decoder
  starts from. A fragment that starts elsewhere replays its GOP from the last
  IDR, up to 1,200 frames back; past that, or after a seek, frames before the
  next IDR are dropped, as the engine itself would.
- A variable-frame-rate stream with B-frames can look like it ends mid-GOP,
  and then holds its last frames until the next append; the very last
  append's are lost.
