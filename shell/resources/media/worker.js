'use strict';

const RECORD = 40;
const GROUP = 32;
const KEY = 1;
const DECODE_ONLY = 2;
const FLUSH = 4;
const FINISH = 8;
const ENCODE_KEY = 2;
const VP9 = 'vp09.00.41.08';

const tuned = self.mbgaTune || {};
let tune = { ...tuned };
const QUEUE = () => tune.queue || 4;
const IDLE = () => tune.idle || 8;
const TIMEOUT = 20000;
const BIG_MEMORY = () => tune.bigMemory || 64 << 20;
const REST = () => tune.rest || 20000;
const MIN_DISPLAY = 32;
const HYSTERESIS = 0.25;
const FPS_CHANGE = 0.1;
const BPP = 0.1;

const stats = {
  decoded: 0,
  decodeOnly: 0,
  dropped: 0,
  capped: 0,
  encoded: 0,
  keys: 0,
  encodedBytes: 0,
  resized: 0,
  rerated: 0,
  recycled: 0,
  rested: 0,
};

let wasm = null;
let spare = null;
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
  } else if (msg.type === 'tune') {
    tune = { ...tuned, ...msg.tune };
  } else if (fatal) {
    refuse(msg);
  } else if (wasm) {
    dispatch(msg);
  } else {
    early.push(msg);
  }
};

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
  msg.module = null;
  try {
    const compiled = module instanceof WebAssembly.Module ? module : await WebAssembly.compile(module);
    spare = new WebAssembly.Instance(compiled, {});
    wasm = compiled;
  } catch (e) {
    fatal = 'could not load the converter: ' + describe(e);
    self.postMessage({ type: 'fatal', message: fatal });
    for (const queued of early.splice(0)) refuse(queued);
    return;
  }
  self.postMessage({ type: 'ready' });
  for (const queued of early.splice(0)) dispatch(queued);
}

function refuse(msg) {
  if (msg.type === 'append' || msg.type === 'drain') {
    self.postMessage({ type: 'error', sb: msg.sb, seq: msg.seq, message: fatal });
  }
}

function dispatch(msg) {
  let stream = streams.get(msg.sb);
  if (!stream) {
    if (msg.type === 'close' || msg.type === 'keepalive') return;
    stream = new Stream(msg.sb);
    streams.set(msg.sb, stream);
  }
  if (msg.type === 'size') {
    stream.display = { width: msg.width, height: msg.height };
    stream.fps = msg.fps > 0 ? msg.fps : 0;
    return;
  }
  if (msg.type === 'keepalive') {
    stream.rest();
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
    this.startAt = 0;
    this.ex = null;
    this.h = 0;
    this.init = null;
    this.initGeneration = 0;
    this.mime = '';
    this.display = null;
    this.fps = 0;
    this.video = new Map();
    this.restTimer = 0;
  }

  async handle(msg) {
    switch (msg.type) {
      case 'open':
        this.close();
        this.progressive = msg.mime === 'progressive';
        this.startAt = this.progressive && msg.start > 0 ? msg.start : 0;
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

  rest() {
    clearTimeout(this.restTimer);
    this.restTimer = 0;
    if (!this.video.size) return;
    this.restTimer = setTimeout(() => {
      this.restTimer = 0;
      this.queue = this.queue.then(() => this.closeIdle()).catch((e) => console.error('MBGA media:', e));
    }, REST());
  }

  async closeIdle() {
    if (!this.video.size || streams.get(this.sb) !== this) return;
    try {
      for (const [track, v] of this.video) {
        if (v.decoder.state === 'configured') await within(v.decoder.flush(), 'decoding');
        if (v.encoder && v.encoder.state === 'configured') await within(v.encoder.flush(), 'encoding');
        if (v.error) throw v.error;
        if (this.h) this.ex.mm_flushed(this.h, track);
      }
      this.closeCodecs();
      stats.rested++;
    } catch (e) {
      this.closeCodecs();
      if (this.h) this.ex.mm_restart(this.h);
    }
    if (this.h && this.ex.memory.buffer.byteLength > BIG_MEMORY() && this.ex.mm_recyclable(this.h)) this.recycle();
  }

  start() {
    const instance = spare || new WebAssembly.Instance(wasm, {});
    spare = null;
    this.ex = instance.exports;
    this.h = this.ex.mm_create(this.progressive ? 1 : 0);
    if (this.startAt) this.ex.mm_start(this.h, this.startAt);
    this.initGeneration = 0;
    if (this.init) {
      this.push(this.init);
      this.ex.mm_poll(this.h);
      this.ex.mm_output_clear(this.h);
      this.initGeneration = this.ex.mm_init_generation(this.h);
    }
  }

  drop() {
    if (this.h) this.ex.mm_destroy(this.h);
    this.ex = null;
    this.h = 0;
  }

  close() {
    clearTimeout(this.restTimer);
    this.restTimer = 0;
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
      this.ex.mm_begin(this.h, msg.seq);
      const offset = this.progressive && typeof msg.offset === 'number' ? msg.offset : -1;
      if (offset < 0 || this.ex.mm_offset(this.h, offset)) this.push(bytes);
      bytes = null;
      for (;;) {
        const status = this.ex.mm_poll(this.h);
        if (status < 0) throw new ModuleError(this.string('error'));
        if (status === 0) break;
        await this.runJob();
      }
      if (this.ex.mm_write(this.h) < 0) throw new ModuleError(this.string('error'));
      this.reply(msg);
    } catch (e) {
      this.fail(msg, e);
    }
    this.rest();
  }

  async drain(msg) {
    try {
      if (this.h) {
        this.checkCodecs();
        this.ex.mm_begin(this.h, msg.seq);
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
    this.rest();
  }

  reply(msg) {
    const out = { type: 'output', sb: this.sb, seq: msg.seq, bytes: new ArrayBuffer(0) };
    const transfer = [];
    if (this.h) {
      const ex = this.ex;
      const h = this.h;
      const count = ex.mm_held_count(h);
      if (count) {
        const view = new DataView(ex.memory.buffer, ex.mm_held_groups(h), count * GROUP);
        const base = ex.mm_held_ptr(h);
        out.held = [];
        for (let i = 0; i < count; i++) {
          const at = i * GROUP;
          const bytes = this.copy(base + view.getUint32(at + 24, true), view.getUint32(at + 28, true));
          out.held.push({
            seq: view.getFloat64(at, true),
            bytes: bytes.buffer,
            start: view.getFloat64(at + 8, true),
            end: view.getFloat64(at + 16, true),
          });
          transfer.push(bytes.buffer);
        }
      }
      const bytes = this.copy(ex.mm_output_ptr(h), ex.mm_output_len(h));
      out.bytes = bytes.buffer;
      transfer.push(bytes.buffer);
      const start = ex.mm_output_start(h);
      if (Number.isFinite(start)) out.range = { start, end: ex.mm_output_end(h) };
      if (ex.mm_natural_width(h) > 0) {
        const natural = { width: ex.mm_natural_width(h), height: ex.mm_natural_height(h) };
        const at = ex.mm_natural_at(h);
        if (Number.isFinite(at)) natural.at = at;
        const seq = ex.mm_natural_seq(h);
        if (seq !== msg.seq) natural.seq = seq;
        out.natural = natural;
      }
      const need = ex.mm_need(h);
      if (need >= 0) out.need = need;
      ex.mm_output_clear(h);
      const mime = this.string('mime');
      if (mime !== this.mime) {
        out.mime = this.mime = mime;
      }
    }
    msg.replied = true;
    self.postMessage(out, transfer);
    if (this.h) {
      this.keepInit();
      if (this.ex.memory.buffer.byteLength > BIG_MEMORY() && this.ex.mm_recyclable(this.h)) this.recycle();
    }
  }

  recycle() {
    const ex = this.ex;
    const h = this.h;
    const len = ex.mm_save_state(h);
    const state = this.copy(ex.mm_state_ptr(h), len);
    this.ex = null;
    this.h = 0;
    try {
      this.start();
      const ptr = this.ex.mm_state_buffer(this.h, state.length);
      if (!ptr) throw new Error('out of memory');
      new Uint8Array(this.ex.memory.buffer, ptr, state.length).set(state);
      if (this.ex.mm_load_state(this.h, state.length) < 0) throw new ModuleError(this.string('error'));
      ex.mm_destroy(h);
      stats.recycled++;
    } catch (e) {
      console.error('MBGA media: recycling:', e);
      if (this.h) this.ex.mm_destroy(this.h);
      this.ex = ex;
      this.h = h;
    }
  }

  fail(msg, e) {
    if (e instanceof WebAssembly.RuntimeError) {
      this.ex = null;
      this.h = 0;
      this.closeCodecs();
    } else if (this.h) {
      this.ex.mm_output_discard(this.h);
      if (!(e instanceof ModuleError)) {
        this.closeCodecs();
        this.ex.mm_restart(this.h);
      }
    }
    if (msg.replied) {
      console.error('MBGA media:', e);
      return;
    }
    msg.replied = true;
    self.postMessage({ type: 'error', sb: this.sb, seq: msg.seq, message: describe(e) });
  }

  push(bytes) {
    const ex = this.ex;
    const ptr = ex.mm_reserve(this.h, bytes.length);
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

  async decode(track, samples) {
    if (samples.every((s) => s.flags & FINISH)) {
      const v = this.video.get(track);
      if (v) {
        if (v.decoder.state === 'configured') await within(v.decoder.flush(), 'decoding');
        if (v.encoder && v.encoder.state === 'configured') await within(v.encoder.flush(), 'encoding');
        if (v.error) throw v.error;
      }
      this.ex.mm_flushed(this.h, track);
      return;
    }
    const v = this.track(track);
    const codec = 'avc1.' + samples[0].codec.toString(16).padStart(6, '0');
    if (v.codec !== codec) {
      if (v.codec) {
        await within(v.decoder.flush(), 'decoding');
      }
      v.decoder.configure({ codec });
      v.codec = codec;
    }
    v.bitrate = samples[0].bitrate;
    v.framerate = samples[0].duration > 0 ? Math.min(240, Math.max(1, 1e6 / samples[0].duration)) : 30;
    let flush = false;
    for (const s of samples) {
      await this.room(v);
      if (v.error) throw v.error;
      if (s.flags & DECODE_ONLY) {
        stats.decodeOnly++;
      } else if (s.flags & KEY) {
        v.keys.push(s.timestamp);
        if (v.keys.length > 256) v.keys.shift();
      }
      flush ||= !!(s.flags & FLUSH);
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
      config: null,
      outWidth: 0,
      outHeight: 0,
      bitrate: 0,
      framerate: 30,
      cadence: null,
      keys: [],
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

  async room(v) {
    const started = performance.now();
    while (v.decoder.decodeQueueSize > QUEUE() || (v.encoder && v.encoder.encodeQueueSize > QUEUE())) {
      if (v.error) return;
      if (performance.now() - started > TIMEOUT) throw new Error('decoding timed out');
      await nap(v, 50);
    }
  }

  async settle(v) {
    const started = performance.now();
    while (!v.error && performance.now() - started < TIMEOUT) {
      if (v.decoder.decodeQueueSize > 0) {
        await nap(v, IDLE());
        continue;
      }
      const quiet = performance.now() - v.active;
      if (quiet >= IDLE()) return;
      await sleep(IDLE() - quiet);
    }
  }

  output(v, frame) {
    try {
      stats.decoded++;
      v.active = performance.now();
      if (v.error) return;
      const ts = frame.timestamp;
      if (!this.h || this.video.get(v.track) !== v) {
        stats.dropped++;
        return;
      }
      while (v.keys.length && v.keys[0] < ts) v.keys.shift();
      const slot = this.capped(v, ts);
      const skip = slot < 0;
      const rect = frame.visibleRect;
      const width = rect ? rect.width : frame.displayWidth;
      const height = rect ? rect.height : frame.displayHeight;
      const what = this.ex.mm_frame(this.h, v.track, ts, skip ? 1 : 0, width, height);
      if (!what) {
        stats[skip ? 'capped' : 'dropped']++;
        return;
      }
      this.kept(v, ts, slot, what === ENCODE_KEY);
      this.encode(v, frame, what === ENCODE_KEY);
    } catch (e) {
      v.error ||= e;
    } finally {
      frame.close();
    }
  }

  capped(v, ts) {
    const fps = this.fps;
    if (!(fps > 0)) {
      v.cadence = null;
      return 0;
    }
    const period = 1e6 / fps;
    const half = Math.min(period, 1e6 / v.framerate) / 2;
    let c = v.cadence;
    if (!c || c.fps !== fps || ts <= c.last || ts - c.last > 1e6) {
      c = v.cadence = { fps, origin: ts, slot: -1, last: ts, half, period };
    }
    c.last = ts;
    const slotOf = (t) => Math.floor((t - c.origin + c.half) / c.period);
    const slot = slotOf(ts);
    if (slot <= c.slot) return -1;
    if (v.keys.some((k) => k > ts && slotOf(k) === slot)) return -1;
    return slot;
  }

  kept(v, ts, slot, key) {
    const c = v.cadence;
    if (!c) return;
    if (key) {
      c.origin = ts;
      c.slot = 0;
    } else {
      c.slot = Math.max(c.slot, slot);
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
      const resized = !v.config || v.config.width !== config.width || v.config.height !== config.height;
      const options = {
        codec: VP9,
        width: config.width,
        height: config.height,
        framerate: config.fps,
        latencyMode: 'realtime',
      };
      if (tune.bitrateMode) options.bitrateMode = tune.bitrateMode;
      if (tune.quantizer) {
        options.bitrateMode = 'quantizer';
      } else {
        options.bitrate = this.bitrate(v, config);
      }
      v.encoder.configure(options);
      if (v.config) stats[resized ? 'resized' : 'rerated']++;
      v.config = config;
      if (resized) keyFrame = true;
    }
    const options = { keyFrame };
    if (tune.quantizer) options.vp9 = { quantizer: tune.quantizer };
    v.encoder.encode(frame, options);
  }

  target(v, width, height, key) {
    const current = v.config;
    const sameSource = current && current.sourceWidth === width && current.sourceHeight === height;
    const fps = this.fps > 0 ? Math.min(v.framerate, this.fps) : v.framerate;
    let scale = 1;
    const display = this.display;
    if (display && display.width >= MIN_DISPLAY && display.height >= MIN_DISPLAY) {
      scale = Math.min(1, display.width / width, display.height / height);
    } else if (sameSource) {
      scale = current.scale;
    }
    if (sameSource && Math.abs(scale - current.scale) <= HYSTERESIS * current.scale) {
      const same = key ? fps === current.fps : Math.abs(fps - current.fps) <= FPS_CHANGE * current.fps;
      return same ? current : { ...current, fps };
    }
    const even = (x) => Math.max(2, Math.round(x / 2) * 2);
    return {
      sourceWidth: width,
      sourceHeight: height,
      scale,
      width: scale === 1 ? width : even(width * scale),
      height: scale === 1 ? height : even(height * scale),
      fps,
    };
  }

  bitrate(v, config) {
    const pixels = (config.width * config.height) / (config.sourceWidth * config.sourceHeight);
    let rate = (tune.factor || 1) * (v.bitrate || 1e6) * Math.pow(pixels, tune.exponent ?? 0.75);
    rate *= config.fps / v.framerate;
    rate = Math.min(rate, (tune.bpp || BPP) * config.width * config.height * config.fps);
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
