// Converts the H.264 and AAC a page appends to a SourceBuffer into VP9 and
// FLAC, which the engine can play. shim.js starts this worker, posts the
// converter's WebAssembly module, then forwards each SourceBuffer's
// appends; every append gets exactly one reply, in order: `output` with the
// converted bytes (possibly empty), or `error`.
//
// The module (media/, Rust) parses and writes MP4 and turns AAC into FLAC.
// Video needs the engine's codecs, so for each fragment with H.264 the
// module hands back a job: its samples as Annex-B, which a VideoDecoder
// decodes through VideoToolbox and a VideoEncoder encodes to VP9. The
// encoded chunks go back to the module, which writes the fragment with the
// original timestamps.
'use strict';

// One record of the module's JobSample, and its flags (media/src/conv.rs).
const RECORD = 48;
const KEY = 1;
const DECODE_ONLY = 2;
const UNHELD = 4;
const VP9 = 'vp09.00.41.08';

let wasm = null;
const early = [];
const streams = new Map();

self.onmessage = (event) => {
  const msg = event.data;
  if (msg.type === 'wasm') {
    load(msg.module);
  } else if (wasm) {
    dispatch(msg);
  } else {
    early.push(msg);
  }
};

async function load(module) {
  try {
    wasm = module instanceof WebAssembly.Module ? module : await WebAssembly.compile(module);
  } catch (e) {
    console.error('MBGA media: could not load the converter', e);
    return;
  }
  for (const msg of early.splice(0)) dispatch(msg);
}

// Each SourceBuffer's messages run one after another; different
// SourceBuffers convert side by side.
function dispatch(msg) {
  let stream = streams.get(msg.sb);
  if (!stream) {
    stream = new Stream(msg.sb);
    streams.set(msg.sb, stream);
  }
  if (msg.type === 'close') streams.delete(msg.sb);
  stream.queue = stream.queue.then(() => stream.handle(msg));
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
    // Per video track id: its decoder and encoder.
    this.video = new Map();
  }

  async handle(msg) {
    switch (msg.type) {
      case 'open':
        this.close();
        this.progressive = msg.mime === 'progressive';
        this.init = null;
        this.initGeneration = 0;
        break;
      case 'append':
        await this.append(msg.seq, msg.bytes);
        break;
      case 'reset':
        if (this.h) this.ex.mm_reset(this.h);
        for (const v of this.video.values()) dropHeld(v);
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

  close() {
    if (this.h) this.ex.mm_destroy(this.h);
    this.ex = null;
    this.h = 0;
    for (const v of this.video.values()) closeCodecs(v);
    this.video.clear();
  }

  async append(seq, bytes) {
    try {
      if (!this.h) this.start();
      this.push(new Uint8Array(bytes));
      for (;;) {
        const status = this.ex.mm_poll(this.h);
        if (status < 0) throw new Error(this.string('error'));
        if (status === 0) break;
        await this.runJob();
      }
      const out = this.take();
      const mime = this.string('mime');
      const reply = { type: 'output', sb: this.sb, seq, bytes: out.buffer };
      if (mime !== this.mime) {
        // The converted init's type, for SourceBuffers made after the fact
        // (progressive files).
        reply.mime = this.mime = mime;
      }
      self.postMessage(reply, [out.buffer]);
      this.keepInit();
    } catch (e) {
      if (e instanceof WebAssembly.RuntimeError) {
        // A trap (a panic on bad input) leaves the instance unusable; the
        // next append starts a new one from the last init.
        this.ex = null;
        this.h = 0;
        for (const v of this.video.values()) closeCodecs(v);
        this.video.clear();
      } else if (this.h) {
        // Whatever the failed job left in the output is incomplete.
        this.ex.mm_output_clear(this.h);
      }
      self.postMessage({ type: 'error', sb: this.sb, seq, message: String(e && e.message || e) });
    }
  }

  push(bytes) {
    const ex = this.ex;
    const ptr = ex.mm_alloc(bytes.length);
    new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
    ex.mm_push(this.h, ptr, bytes.length);
    ex.mm_free(ptr, bytes.length);
  }

  take() {
    const ex = this.ex;
    const len = ex.mm_output_len(this.h);
    const out = new Uint8Array(ex.memory.buffer, ex.mm_output_ptr(this.h), len).slice();
    ex.mm_output_clear(this.h);
    return out;
  }

  string(name) {
    const ex = this.ex;
    const len = ex[`mm_${name}_len`](this.h);
    return new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ex[`mm_${name}_ptr`](this.h), len));
  }

  keepInit() {
    if (!this.h) return;
    const generation = this.ex.mm_init_generation(this.h);
    if (generation === this.initGeneration) return;
    this.initGeneration = generation;
    const ex = this.ex;
    this.init = new Uint8Array(ex.memory.buffer, ex.mm_init_ptr(this.h), ex.mm_init_len(this.h)).slice();
  }

  async runJob() {
    const ex = this.ex;
    const count = ex.mm_job_len(this.h);
    const view = new DataView(ex.memory.buffer, ex.mm_job_samples(this.h), count * RECORD);
    const samples = [];
    for (let i = 0; i < count; i++) {
      const at = i * RECORD;
      samples.push({
        track: view.getUint32(at, true),
        flags: view.getUint32(at + 4, true),
        offset: view.getUint32(at + 8, true),
        len: view.getUint32(at + 12, true),
        timestamp: view.getFloat64(at + 16, true),
        duration: view.getFloat64(at + 24, true),
        codec: view.getUint32(at + 32, true),
        bitrate: view.getUint32(at + 36, true),
        holdFrom: view.getFloat64(at + 40, true),
      });
    }
    const tracks = new Map();
    for (const s of samples) {
      if (!tracks.has(s.track)) tracks.set(s.track, []);
      tracks.get(s.track).push(s);
    }
    for (const [track, list] of tracks) {
      const chunks = await this.transcode(track, list, ex.mm_job_data(this.h));
      for (const c of chunks) {
        const ptr = ex.mm_alloc(c.data.length);
        new Uint8Array(ex.memory.buffer, ptr, c.data.length).set(c.data);
        const status = ex.mm_chunk(this.h, track, c.timestamp, c.key ? 1 : 0, ptr, c.data.length);
        ex.mm_free(ptr, c.data.length);
        if (status < 0) throw new Error(this.string('error'));
      }
    }
    if (ex.mm_finish(this.h) < 0) throw new Error(this.string('error'));
  }

  // Decodes one track's samples and encodes its frames to VP9. Nothing
  // calls into the module meanwhile, so `data` stays where it is.
  async transcode(track, samples, data) {
    let v = this.video.get(track);
    if (!v) {
      v = { decoder: null, encoder: null, codec: '', width: 0, height: 0, job: null, error: null, held: [] };
      this.video.set(track, v);
    }
    const codec = 'avc1.' + samples[0].codec.toString(16).padStart(6, '0');
    if (!v.decoder || v.decoder.state === 'closed' || v.codec !== codec) {
      if (v.decoder && v.decoder.state !== 'closed') v.decoder.close();
      v.decoder = new VideoDecoder({
        output: (frame) => this.encode(v, frame),
        error: (e) => { v.error = e; },
      });
      // No description: the engine decodes H.264 only as Annex-B.
      // VideoDecoder.isConfigSupported() says no, but decoding works.
      v.decoder.configure({ codec });
      v.codec = codec;
    }
    v.error = null;
    if (samples[0].flags & UNHELD) dropHeld(v);
    v.job = {
      skip: new Set(samples.filter((s) => s.flags & DECODE_ONLY).map((s) => s.timestamp)),
      holdFrom: samples[0].holdFrom,
      bitrate: samples[0].bitrate,
      framerate: samples[0].duration > 0 ? 1e6 / samples[0].duration : 30,
      first: true,
      chunks: [],
    };
    const memory = this.ex.memory.buffer;
    for (const s of samples) {
      v.decoder.decode(new EncodedVideoChunk({
        type: s.flags & KEY ? 'key' : 'delta',
        timestamp: s.timestamp,
        duration: s.duration,
        data: new Uint8Array(memory, data + s.offset, s.len),
      }));
    }
    let failure = null;
    try {
      await v.decoder.flush();
      this.release(v, v.job.holdFrom);
      if (v.encoder) await v.encoder.flush();
    } catch (e) {
      failure = e;
    }
    const chunks = v.job.chunks;
    // Frames still arriving belong to no job.
    v.job = null;
    if (v.error || failure) {
      dropHeld(v);
      throw v.error || failure;
    }
    return chunks;
  }

  // Takes decoded frames in presentation order. A frame from the job's
  // holdFrom on waits for the next job: its fragment ended mid-GOP, and
  // B-frames shown before it are still to come.
  encode(v, frame) {
    const job = v.job;
    if (!job || job.skip.has(frame.timestamp)) {
      frame.close();
      return;
    }
    if (frame.timestamp >= job.holdFrom) {
      v.held.push(frame);
      return;
    }
    this.release(v, frame.timestamp);
    this.encodeFrame(v, frame);
  }

  // Encodes held frames from before `limit`, in order.
  release(v, limit) {
    v.held.sort((a, b) => a.timestamp - b.timestamp);
    while (v.held.length && v.held[0].timestamp < limit) this.encodeFrame(v, v.held.shift());
  }

  encodeFrame(v, frame) {
    const job = v.job;
    const width = frame.visibleRect ? frame.visibleRect.width : frame.displayWidth;
    const height = frame.visibleRect ? frame.visibleRect.height : frame.displayHeight;
    if (!v.encoder || v.encoder.state === 'closed' || v.width !== width || v.height !== height) {
      if (!v.encoder || v.encoder.state === 'closed') {
        v.encoder = new VideoEncoder({
          output: (chunk) => {
            const data = new Uint8Array(chunk.byteLength);
            chunk.copyTo(data);
            if (v.job) v.job.chunks.push({ timestamp: chunk.timestamp, key: chunk.type === 'key', data });
          },
          error: (e) => { v.error = e; },
        });
      }
      v.encoder.configure({
        codec: VP9,
        width,
        height,
        bitrate: job.bitrate,
        framerate: job.framerate,
        latencyMode: 'realtime',
      });
      v.width = width;
      v.height = height;
    }
    // Every fragment starts with a keyframe, so each decodes on its own.
    v.encoder.encode(frame, { keyFrame: job.first });
    job.first = false;
    frame.close();
  }
}

function closeCodecs(v) {
  dropHeld(v);
  for (const codec of [v.decoder, v.encoder]) {
    if (codec && codec.state !== 'closed') codec.close();
  }
}

function dropHeld(v) {
  for (const frame of v.held) frame.close();
  v.held = [];
}
