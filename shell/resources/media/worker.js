// Converts the H.264 and AAC a page appends to a SourceBuffer into VP9 and
// FLAC, which the engine can play. shim.js starts this worker, posts the
// converter's WebAssembly module, then forwards each SourceBuffer's
// messages; every append and every drain gets exactly one reply, in order:
// `output` with the converted bytes (possibly empty), or `error`. If the
// module can't load, `fatal` says so once and every append fails.
//
// The module (media/, Rust) parses and writes MP4 and turns AAC into FLAC.
// Video needs the engine's codecs, so for each fragment with H.264 the
// module hands back a job: its samples as Annex-B, which a VideoDecoder
// decodes through VideoToolbox and a VideoEncoder encodes to VP9. The
// decoder carries on from one job to the next; each frame it puts out is
// encoded, and its chunk goes back to the module, which writes fragments
// with the original timestamps. A decoder holds its last few frames until
// more input comes, so those come out with a later append's output, as
// `held`, unless the module says flushing costs nothing.
'use strict';

// One record of the module's JobSample, and its flags (media/src/conv.rs).
const RECORD = 40;
const KEY = 1;
const DECODE_ONLY = 2;
const FLUSH = 4;
const VP9 = 'vp09.00.41.08';

// Settings the harness (media/harness) can change to compare.
const tune = self.mbgaTune || {};
// Decodes and encodes waiting in the codecs' queues before feeding stops:
// decoded 1080p frames are 3 MB each.
const QUEUE = tune.queue || 4;
// After the last decode, how long without a frame coming out means the
// decoder is holding the rest for more input.
const IDLE = tune.idle || 8;
// How long a codec may take to flush before the append fails.
const TIMEOUT = 20000;
// A module instance whose memory grew past this is replaced when nothing
// waits in it: WebAssembly memory never shrinks.
const BIG_MEMORY = tune.bigMemory || 64 << 20;
// A page's element smaller than this is hidden or collapsed: its size
// says nothing about how big the video will be shown.
const MIN_DISPLAY = 32;
// The displayed size has to change by more than this to re-encode at it.
const HYSTERESIS = 0.25;
// The most bits per pixel to encode at: 6 Mbps at 1080p30.
const BPP = 0.1;

// What the codecs did, for the harness ({type: 'stats'}).
const stats = { decoded: 0, decodeOnly: 0, dropped: 0, encoded: 0, keys: 0, encodedBytes: 0, resized: 0, recycled: 0 };

let wasm = null;
let fatal = null;
const early = [];
const streams = new Map();

class ModuleError extends Error {}

self.onmessage = (event) => {
  const msg = event.data;
  if (msg.type === 'wasm') {
    load(msg);
  } else if (msg.type === 'stats') {
    self.postMessage({ type: 'stats', ...stats });
  } else if (fatal) {
    refuse(msg);
  } else if (wasm) {
    dispatch(msg);
  } else {
    early.push(msg);
  }
};

// Nothing should get this far; if something does, the other streams carry
// on, and the stream's own messages still get their replies.
self.addEventListener('error', (event) => {
  event.preventDefault();
  console.error('MBGA media:', event.message);
});
self.addEventListener('unhandledrejection', (event) => {
  event.preventDefault();
  console.error('MBGA media:', event.reason);
});

async function load(msg) {
  const module = msg.module;
  // The bytes aren't needed once compiled.
  msg.module = null;
  try {
    wasm = module instanceof WebAssembly.Module ? module : await WebAssembly.compile(module);
  } catch (e) {
    fatal = 'could not load the converter: ' + describe(e);
    self.postMessage({ type: 'fatal', message: fatal });
    for (const queued of early.splice(0)) refuse(queued);
    return;
  }
  for (const queued of early.splice(0)) dispatch(queued);
}

function refuse(msg) {
  if (msg.type === 'append' || msg.type === 'drain') {
    self.postMessage({ type: 'error', sb: msg.sb, seq: msg.seq, message: fatal });
  }
}

// Each SourceBuffer's messages run one after another; different
// SourceBuffers convert side by side. `size` applies at once.
function dispatch(msg) {
  let stream = streams.get(msg.sb);
  if (!stream) {
    if (msg.type === 'close') return;
    stream = new Stream(msg.sb);
    streams.set(msg.sb, stream);
  }
  if (msg.type === 'size') {
    stream.display = { width: msg.width, height: msg.height };
    return;
  }
  if (msg.type === 'close') streams.delete(msg.sb);
  stream.queue = stream.queue
    .then(() => stream.handle(msg))
    .catch((e) => {
      console.error('MBGA media:', e);
      if ((msg.type === 'append' || msg.type === 'drain') && !msg.replied) {
        msg.replied = true;
        self.postMessage({ type: 'error', sb: msg.sb, seq: msg.seq, message: describe(e) });
      }
    });
}

function describe(e) {
  return String((e && e.message) || e);
}

function within(promise, what) {
  let timer;
  return Promise.race([
    promise,
    new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error(what + ' timed out')), TIMEOUT);
    }),
  ]).finally(() => clearTimeout(timer));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Sleeps until a codec of `v` dequeues something or fails, or `ms` pass.
function nap(v, ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(done, ms);
    function done() {
      clearTimeout(timer);
      v.wake = null;
      resolve();
    }
    v.wake = done;
  });
}

class Stream {
  constructor(sb) {
    this.sb = sb;
    this.queue = Promise.resolve();
    this.progressive = false;
    this.ex = null;
    this.h = 0;
    // The last input init segment, to start over with if the module traps.
    this.init = null;
    this.initGeneration = 0;
    this.mime = '';
    // Device pixels of the element showing this SourceBuffer, if known.
    this.display = null;
    // Per video track id: its decoder, encoder and what's in flight.
    this.video = new Map();
  }

  async handle(msg) {
    switch (msg.type) {
      case 'open':
        this.close();
        this.progressive = msg.mime === 'progressive';
        this.init = null;
        this.initGeneration = 0;
        this.mime = '';
        break;
      case 'append':
        await this.append(msg);
        break;
      case 'drain':
        await this.drain(msg);
        break;
      case 'reset':
        if (this.h) this.ex.mm_reset(this.h);
        this.closeCodecs();
        break;
      case 'close':
        this.close();
        break;
    }
  }

  // A module instance per SourceBuffer, so a trap in one (a panic on bad
  // input) loses nothing elsewhere.
  start() {
    this.ex = new WebAssembly.Instance(wasm, {}).exports;
    this.h = this.ex.mm_create(this.progressive ? 1 : 0);
    this.initGeneration = 0;
    if (this.init) {
      this.push(this.init);
      this.ex.mm_poll(this.h);
      this.ex.mm_output_clear(this.h);
      this.initGeneration = this.ex.mm_init_generation(this.h);
    }
  }

  // Lets the instance go (and its memory with it).
  drop() {
    if (this.h) this.ex.mm_destroy(this.h);
    this.ex = null;
    this.h = 0;
  }

  close() {
    this.drop();
    this.closeCodecs();
  }

  closeCodecs() {
    for (const v of this.video.values()) {
      for (const codec of [v.decoder, v.encoder]) {
        if (codec && codec.state !== 'closed') codec.close();
      }
      if (v.wake) v.wake();
    }
    this.video.clear();
  }

  // Codecs the engine reclaimed or that failed since the last message
  // start over, and the module learns that frames in flight are gone.
  checkCodecs() {
    let lost = false;
    for (const v of this.video.values()) {
      lost ||= !!v.error || [v.decoder, v.encoder].some((c) => c && c.state === 'closed');
    }
    if (lost) {
      this.closeCodecs();
      if (this.h) this.ex.mm_restart(this.h);
    }
  }

  async append(msg) {
    let bytes = new Uint8Array(msg.bytes);
    msg.bytes = null;
    try {
      if (!this.h) this.start();
      this.checkCodecs();
      this.ex.mm_begin(this.h);
      this.push(bytes);
      bytes = null;
      for (;;) {
        const status = this.ex.mm_poll(this.h);
        if (status < 0) throw new ModuleError(this.string('error'));
        if (status === 0) break;
        await this.runJob();
      }
      // Chunks of frames the decoder put out late, since the last job.
      if (this.ex.mm_write(this.h) < 0) throw new ModuleError(this.string('error'));
      this.reply(msg);
    } catch (e) {
      this.fail(msg, e);
    }
  }

  // Everything the decoders still hold, before the page ends the stream.
  async drain(msg) {
    try {
      if (this.h) {
        this.checkCodecs();
        this.ex.mm_begin(this.h);
        for (const [track, v] of this.video) {
          if (v.decoder.state === 'configured') await within(v.decoder.flush(), 'decoding');
          if (v.encoder && v.encoder.state === 'configured') await within(v.encoder.flush(), 'encoding');
          if (v.error) throw v.error;
          this.ex.mm_flushed(this.h, track);
        }
        if (this.ex.mm_write(this.h) < 0) throw new ModuleError(this.string('error'));
      }
      this.reply(msg);
    } catch (e) {
      this.fail(msg, e);
    }
  }

  reply(msg) {
    const out = { type: 'output', sb: this.sb, seq: msg.seq, bytes: new ArrayBuffer(0) };
    const transfer = [];
    if (this.h) {
      const ex = this.ex;
      const held = this.copy(ex.mm_held_ptr(this.h), ex.mm_held_len(this.h));
      const bytes = this.copy(ex.mm_output_ptr(this.h), ex.mm_output_len(this.h));
      ex.mm_output_clear(this.h);
      out.bytes = bytes.buffer;
      transfer.push(bytes.buffer);
      if (held.length) {
        // Frames of earlier appends, to append with their settings first.
        out.held = held.buffer;
        transfer.push(held.buffer);
      }
      const mime = this.string('mime');
      if (mime !== this.mime) {
        // The converted init's type, for SourceBuffers made after the fact
        // (progressive files).
        out.mime = this.mime = mime;
      }
    }
    msg.replied = true;
    self.postMessage(out, transfer);
    if (this.h) {
      this.keepInit();
      if (this.ex.memory.buffer.byteLength > BIG_MEMORY && this.ex.mm_recyclable(this.h)) {
        stats.recycled++;
        this.drop();
      }
    }
  }

  fail(msg, e) {
    if (e instanceof WebAssembly.RuntimeError) {
      // A trap (a panic on bad input) leaves the instance unusable; the
      // next append starts a new one from the last init.
      this.ex = null;
      this.h = 0;
      this.closeCodecs();
    } else if (this.h) {
      // Whatever the failed job left in the output is incomplete.
      this.ex.mm_output_clear(this.h);
      if (!(e instanceof ModuleError)) {
        // The codecs failed: start them over.
        this.closeCodecs();
        this.ex.mm_restart(this.h);
      }
    }
    if (msg.replied) {
      // It failed after its reply went out; the next message starts clean.
      console.error('MBGA media:', e);
      return;
    }
    msg.replied = true;
    self.postMessage({ type: 'error', sb: this.sb, seq: msg.seq, message: describe(e) });
  }

  // Writes input straight into the module's buffer.
  push(bytes) {
    const ex = this.ex;
    const ptr = ex.mm_reserve(this.h, bytes.length);
    // Null past the module's limit, and then the next poll fails.
    if (!ptr) return;
    new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
    ex.mm_commit(this.h, bytes.length);
  }

  copy(ptr, len) {
    return new Uint8Array(this.ex.memory.buffer, ptr, len).slice();
  }

  string(name) {
    const ex = this.ex;
    const len = ex[`mm_${name}_len`](this.h);
    return new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ex[`mm_${name}_ptr`](this.h), len));
  }

  keepInit() {
    const generation = this.ex.mm_init_generation(this.h);
    if (generation === this.initGeneration) return;
    this.initGeneration = generation;
    this.init = this.copy(this.ex.mm_init_ptr(this.h), this.ex.mm_init_len(this.h));
  }

  async runJob() {
    const ex = this.ex;
    const count = ex.mm_job_len(this.h);
    const view = new DataView(ex.memory.buffer, ex.mm_job_samples(this.h), count * RECORD);
    const tracks = new Map();
    for (let i = 0; i < count; i++) {
      const at = i * RECORD;
      const s = {
        track: view.getUint32(at, true),
        flags: view.getUint32(at + 4, true),
        offset: view.getUint32(at + 8, true),
        len: view.getUint32(at + 12, true),
        timestamp: view.getFloat64(at + 16, true),
        duration: view.getFloat64(at + 24, true),
        codec: view.getUint32(at + 32, true),
        bitrate: view.getUint32(at + 36, true),
      };
      if (!tracks.has(s.track)) tracks.set(s.track, []);
      tracks.get(s.track).push(s);
    }
    for (const [track, samples] of tracks) await this.decode(track, samples);
    if (ex.mm_write(this.h) < 0) throw new ModuleError(this.string('error'));
  }

  // Feeds one track's samples to its decoder, as fast as the encoder keeps
  // up. Frames come out through output() and are encoded there.
  async decode(track, samples) {
    const v = this.track(track);
    const codec = 'avc1.' + samples[0].codec.toString(16).padStart(6, '0');
    if (v.codec !== codec) {
      if (v.codec) {
        // A new stream, starting at a keyframe: what the old one held
        // comes out first.
        await within(v.decoder.flush(), 'decoding');
      }
      // No description: the engine decodes H.264 only as Annex-B.
      // VideoDecoder.isConfigSupported() says no, but decoding works.
      v.decoder.configure({ codec });
      v.codec = codec;
    }
    v.bitrate = samples[0].bitrate;
    v.framerate = samples[0].duration > 0 ? 1e6 / samples[0].duration : 30;
    let flush = false;
    for (const s of samples) {
      await this.room(v);
      if (v.error) throw v.error;
      if (s.flags & DECODE_ONLY) {
        v.skip.add(s.timestamp);
        stats.decodeOnly++;
      } else if (s.flags & KEY) {
        v.keys.add(s.timestamp);
      }
      flush ||= !!(s.flags & FLUSH);
      // Looked up each time: memory may have grown meanwhile.
      const data = new Uint8Array(this.ex.memory.buffer, this.ex.mm_job_data(this.h) + s.offset, s.len);
      v.decoder.decode(new EncodedVideoChunk({
        type: s.flags & KEY ? 'key' : 'delta',
        timestamp: s.timestamp,
        duration: s.duration,
        data,
      }));
      v.active = performance.now();
    }
    if (flush) {
      await within(v.decoder.flush(), 'decoding');
    } else {
      await this.settle(v);
    }
    if (v.encoder && v.encoder.state === 'configured') await within(v.encoder.flush(), 'encoding');
    if (v.error) throw v.error;
    if (flush) this.ex.mm_flushed(this.h, track);
  }

  track(track) {
    let v = this.video.get(track);
    if (v) return v;
    v = {
      track,
      decoder: null,
      encoder: null,
      codec: '',
      // What the encoder is configured for.
      config: null,
      // The coded size of the chunks coming out.
      outWidth: 0,
      outHeight: 0,
      bitrate: 0,
      framerate: 30,
      // Timestamps of frames to decode only, and of keyframes.
      skip: new Set(),
      keys: new Set(),
      active: 0,
      error: null,
      wake: null,
    };
    const wake = () => {
      if (v.wake) v.wake();
    };
    v.decoder = new VideoDecoder({
      output: (frame) => this.output(v, frame),
      error: (e) => {
        v.error ||= e;
        wake();
      },
    });
    v.decoder.addEventListener('dequeue', wake);
    this.video.set(track, v);
    return v;
  }

  // Waits while the decoder or encoder has more than QUEUE waiting.
  async room(v) {
    const started = performance.now();
    while (v.decoder.decodeQueueSize > QUEUE || (v.encoder && v.encoder.encodeQueueSize > QUEUE)) {
      if (v.error) return;
      if (performance.now() - started > TIMEOUT) throw new Error('decoding timed out');
      await nap(v, 50);
    }
  }

  // Lets the frames being decoded come out: the decoder is idle once its
  // queue is empty and nothing came out for a moment. What it holds for
  // more input comes out with the next job.
  async settle(v) {
    const started = performance.now();
    while (!v.error && performance.now() - started < TIMEOUT) {
      if (v.decoder.decodeQueueSize > 0) {
        await nap(v, IDLE);
        continue;
      }
      const quiet = performance.now() - v.active;
      if (quiet >= IDLE) return;
      await sleep(IDLE - quiet);
    }
  }

  output(v, frame) {
    try {
      stats.decoded++;
      v.active = performance.now();
      const ts = frame.timestamp;
      const key = v.keys.delete(ts);
      if (v.skip.delete(ts) || v.error) return;
      // The module says which frames it will write, so the encoder gets
      // exactly those, in order.
      if (!this.h || this.video.get(v.track) !== v || !this.ex.mm_frame(this.h, v.track, ts)) {
        stats.dropped++;
        return;
      }
      this.encode(v, frame, key);
    } catch (e) {
      v.error ||= e;
    } finally {
      frame.close();
    }
  }

  encode(v, frame, key) {
    const width = frame.visibleRect ? frame.visibleRect.width : frame.displayWidth;
    const height = frame.visibleRect ? frame.visibleRect.height : frame.displayHeight;
    if (!v.encoder || v.encoder.state === 'closed') {
      v.encoder = new VideoEncoder({
        output: (chunk, metadata) => this.chunk(v, chunk, metadata),
        error: (e) => {
          v.error ||= e;
          if (v.wake) v.wake();
        },
      });
      v.encoder.addEventListener('dequeue', () => {
        if (v.wake) v.wake();
      });
      v.config = null;
    }
    const config = this.target(v, width, height, key);
    let keyFrame = key;
    if (config !== v.config) {
      const options = {
        codec: VP9,
        width: config.width,
        height: config.height,
        framerate: v.framerate,
        latencyMode: 'realtime',
      };
      if (tune.quantizer) {
        options.bitrateMode = 'quantizer';
      } else {
        options.bitrate = this.bitrate(v, config);
      }
      v.encoder.configure(options);
      if (v.config && (v.config.width !== config.width || v.config.height !== config.height)) stats.resized++;
      v.config = config;
      // A new configuration starts with a keyframe anyway.
      keyFrame = true;
    }
    const options = { keyFrame };
    if (tune.quantizer) options.vp9 = { quantizer: tune.quantizer };
    // The encoder scales the frame to its configured size.
    v.encoder.encode(frame, options);
  }

  // The size to encode at: the source's, or smaller to fit the element
  // showing it, keeping the aspect ratio. Changes only at keyframes, and
  // for a displayed size only when it differs by more than HYSTERESIS.
  target(v, width, height, key) {
    const current = v.config;
    const sameSource = current && current.sourceWidth === width && current.sourceHeight === height;
    if (sameSource && !key) return current;
    let scale = 1;
    const display = this.display;
    if (display && display.width >= MIN_DISPLAY && display.height >= MIN_DISPLAY) {
      scale = Math.min(1, display.width / width, display.height / height);
    } else if (sameSource) {
      scale = current.scale;
    }
    if (sameSource && Math.abs(scale - current.scale) <= HYSTERESIS * current.scale) return current;
    const even = (x) => Math.max(2, Math.round(x / 2) * 2);
    return {
      sourceWidth: width,
      sourceHeight: height,
      scale,
      width: scale === 1 ? width : even(width * scale),
      height: scale === 1 ? height : even(height * scale),
    };
  }

  // Bits per second for the encoder: the source's, for fewer pixels
  // (pixels^0.75, so small encodes don't starve), and at most BPP bits per
  // pixel. Measured on X's 720p in media/harness: twice the source's rate
  // cost 10% more time for 0.8 dB PSNR more, and the quantizer mode was
  // slower and twice as big. tune.factor, .exponent and .bpp change these.
  bitrate(v, config) {
    const pixels = (config.width * config.height) / (config.sourceWidth * config.sourceHeight);
    let rate = (tune.factor || 1) * (v.bitrate || 1e6) * Math.pow(pixels, tune.exponent ?? 0.75);
    rate = Math.min(rate, (tune.bpp || BPP) * config.width * config.height * v.framerate);
    return Math.round(Math.min(40e6, Math.max(100e3, rate)));
  }

  chunk(v, chunk, metadata) {
    try {
      stats.encoded++;
      stats.encodedBytes += chunk.byteLength;
      if (chunk.type === 'key') stats.keys++;
      const config = metadata && metadata.decoderConfig;
      if (config && config.codedWidth) {
        v.outWidth = config.codedWidth;
        v.outHeight = config.codedHeight;
      }
      // Frames from before a reset or a trap have nowhere to go.
      if (!this.h || this.video.get(v.track) !== v) return;
      const ex = this.ex;
      const ptr = ex.mm_chunk_buffer(this.h, chunk.byteLength);
      if (!ptr) throw new Error('out of memory');
      chunk.copyTo(new Uint8Array(ex.memory.buffer, ptr, chunk.byteLength));
      const key = chunk.type === 'key' ? 1 : 0;
      if (ex.mm_chunk(this.h, v.track, chunk.timestamp, key, v.outWidth, v.outHeight, chunk.byteLength) < 0) {
        throw new ModuleError(this.string('error'));
      }
    } catch (e) {
      v.error ||= e;
    }
  }
}
