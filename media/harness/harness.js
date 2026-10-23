// Runs each case in cases.json through worker.js in the real engine and
// appends the output to a real MediaSource, the way shim.js does: `held`
// groups first, then the append's own bytes, and a `drain` before
// endOfStream().
// Results land in window.results; ?case=a,b runs some cases, ?save=1 posts
// each SourceBuffer's converted bytes to serve.py for ffprobe,
// ?tune={...} hands the worker encoder settings to compare (self.mbgaTune),
// and ?repeat=N runs everything N times, for timing.
'use strict';

const params = new URLSearchParams(location.search);
const log = (...args) => {
  document.querySelector('#log').textContent += args.join(' ') + '\n';
};

// What shim.js maps the page's codecs to.
function mapMime(mime) {
  return mime
    .replace(/avc[13]\.[0-9a-fA-F]+/g, 'vp09.00.41.08')
    .replace(/mp4a\.[0-9a-fA-F.]+/g, 'flac');
}

function url(file) {
  return file.startsWith('fixtures/') ? '/media/tests/fixtures/' + file.slice(9) : '/' + file;
}

class Converter {
  constructor(worker) {
    this.worker = worker;
    this.waiting = new Map();
    this.seq = new Map();
    this.fatal = null;
    this.ready = new Promise((resolve) => {
      this.onReady = resolve;
    });
    worker.onmessage = (e) => {
      const msg = e.data;
      if (msg.type === 'fatal') {
        this.fatal = msg.message;
        return;
      }
      if (msg.type === 'ready') {
        this.onReady(performance.now());
        return;
      }
      const key = msg.type === 'stats' ? 'stats' : msg.sb + ':' + msg.seq;
      const done = this.waiting.get(key);
      this.waiting.delete(key);
      if (done) done(msg);
    };
  }

  post(msg, transfer) {
    this.worker.postMessage(msg, transfer || []);
  }

  request(sb, msg, transfer) {
    const seq = (this.seq.get(sb) || 0) + 1;
    this.seq.set(sb, seq);
    return new Promise((resolve) => {
      this.waiting.set(sb + ':' + seq, resolve);
      this.post({ ...msg, sb, seq }, transfer);
    });
  }

  append(sb, bytes, offset) {
    const msg = { type: 'append', bytes };
    if (offset !== undefined) msg.offset = offset;
    return this.request(sb, msg, [bytes]);
  }

  // The seq the next append or drain on `sb` gets.
  next(sb) {
    return (this.seq.get(sb) || 0) + 1;
  }

  drain(sb) {
    return this.request(sb, { type: 'drain' });
  }

  stats() {
    return new Promise((resolve) => {
      this.waiting.set('stats', resolve);
      this.post({ type: 'stats' });
    });
  }
}

async function startWorker() {
  const [source, wasm] = await Promise.all([
    fetch('/shell/resources/media/worker.js').then((r) => r.text()),
    fetch('/media/target/wasm32-unknown-unknown/release/mbga_media.wasm').then((r) => r.arrayBuffer()),
  ]);
  const tune = params.get('tune');
  const prefix = tune ? `self.mbgaTune = ${tune};\n` : '';
  const worker = new Worker(URL.createObjectURL(new Blob([prefix + source], { type: 'text/javascript' })));
  const conv = new Converter(worker);
  // Like the shim: the module comes as bytes (?compiled=1 sends it compiled).
  worker.postMessage({ type: 'wasm', module: params.has('compiled') ? await WebAssembly.compile(wasm) : wasm });
  return conv;
}

function ranges(tr) {
  const out = [];
  for (let i = 0; i < tr.length; i++) out.push([+tr.start(i).toFixed(4), +tr.end(i).toFixed(4)]);
  return out;
}

function appendTo(sb, bytes) {
  return new Promise((resolve, reject) => {
    sb.addEventListener('updateend', resolve, { once: true });
    sb.addEventListener('error', () => reject(new Error('SourceBuffer error')), { once: true });
    sb.appendBuffer(bytes);
  });
}

// Every box of `data` (recursing into containers), as [type, start, end].
function* walk(data, start = 0, end = data.length) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const containers = ['moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf', 'mvex', 'edts'];
  let pos = start;
  while (pos + 8 <= end) {
    let size = view.getUint32(pos);
    const type = String.fromCharCode(...data.subarray(pos + 4, pos + 8));
    let header = 8;
    if (size === 1) {
      size = Number(view.getBigUint64(pos + 8));
      header = 16;
    }
    if (size < header || pos + size > end) return;
    yield [type, pos, pos + size];
    if (containers.includes(type)) yield* walk(data, pos + header, pos + size);
    if (type === 'stsd') yield* walk(data, pos + 16, pos + size);
    pos += size;
  }
}

// Mutates the first box of a type: `set` maps offsets from the box's start
// to u32 values. Malformed input built from good fixtures.
function patch(data, patches) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  for (const p of patches) {
    const box = [...walk(data)].find((b) => b[0] === p.box);
    if (!box) throw new Error('no ' + p.box + ' to patch');
    for (const [at, value] of Object.entries(p.set)) view.setUint32(box[1] + Number(at), value >>> 0);
  }
  return data;
}

// The init, then each moof with its mdat.
function units(data) {
  const out = [];
  let start = 0;
  for (const [type, at] of walk(data)) {
    if (type === 'moof') {
      if (at > start) out.push(data.slice(start, at));
      start = at;
    }
  }
  out.push(data.slice(start));
  return out;
}

// The vp09 sample entries' sizes in some output.
function vp09Sizes(data) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return [...walk(data)].filter((b) => b[0] === 'vp09').map((b) => [view.getUint16(b[1] + 32), view.getUint16(b[1] + 34)]);
}

async function runCase(conv, c, sbBase, expected) {
  const result = { name: c.name, ok: true, problems: [], sbs: [] };
  const fail = (msg) => {
    result.ok = false;
    result.problems.push(msg);
  };
  if (c.tune) conv.post({ type: 'tune', tune: c.tune });
  const before = await conv.stats();
  const video = document.createElement('video');
  video.muted = true;
  video.width = 160;
  document.body.append(video);
  const ms = new MediaSource();
  video.src = URL.createObjectURL(ms);
  await new Promise((r) => ms.addEventListener('sourceopen', r, { once: true }));
  video.addEventListener('error', () => fail('video error: ' + (video.error && video.error.message)));

  // Every SourceBuffer is made before any append, as players do.
  const states = c.sbs.map((spec, i) => {
    const id = sbBase + i;
    conv.post({ type: 'open', sb: id, mime: spec.mime, start: spec.start });
    const out = spec.mime === 'progressive' ? null : mapMime(spec.mime);
    return {
      spec,
      id,
      mime: out,
      sb: out ? ms.addSourceBuffer(out) : null,
      times: [],
      bytes: [],
      sizes: [],
      helds: 0,
      natural: null,
      naturals: [],
      needs: [],
      dropped: 0,
    };
  });
  if (states.some((s) => !s.sb) && states.length > 1) throw new Error('one progressive SourceBuffer per case');

  const deliver = async (s, label, reply) => {
    if (!s.sb && reply.mime) {
      s.mime = reply.mime;
      s.sb = ms.addSourceBuffer(reply.mime);
    }
    if (reply.natural) {
      const n = reply.natural;
      s.natural = [n.width, n.height];
      s.naturals.push([n.width, n.height, n.at === undefined ? null : +n.at.toFixed(3)]);
      if (n.seq !== undefined && !(n.seq < reply.seq)) fail(`${label}: natural of append ${n.seq} in ${reply.seq}`);
    }
    // The output's times: there with media, within the input's.
    const media = reply.bytes && [...walk(new Uint8Array(reply.bytes))].some((b) => b[0] === 'moof');
    if (media !== !!reply.range) fail(`${label}: range ${JSON.stringify(reply.range)} for ${media ? 'media' : 'no media'}`);
    if (reply.range) {
      const { start, end } = reply.range;
      const want = s.want;
      if (!(end > start) || (want && (start < want[0] - 0.1 || end > want[1] + 0.1))) {
        fail(`${label}: range ${start}..${end} outside ${JSON.stringify(want)}`);
      }
    }
    const parts = [];
    for (const g of reply.held || []) {
      // Each group is an earlier append's, with that append's settings (the
      // same throughout here), and a time range within the input's.
      if (!(g.seq < reply.seq) || !(g.end > g.start) || !(g.bytes.byteLength > 0)) {
        fail(`${label}: bad held group ${JSON.stringify({ seq: g.seq, start: g.start, end: g.end })} in ${reply.seq}`);
      }
      s.helds++;
      parts.push(g.bytes);
    }
    parts.push(reply.bytes);
    for (const part of parts) {
      if (!part || !part.byteLength) continue;
      const bytes = new Uint8Array(part);
      s.bytes.push(bytes);
      s.sizes.push(...vp09Sizes(bytes));
      try {
        await appendTo(s.sb, part);
      } catch (e) {
        fail(`${label}: ${e.message}`);
      }
    }
  };

  for (const [i, s] of states.entries()) s.want = (c.expected && c.expected[i]) || (expected && expected[i]);
  await Promise.all(states.map(async (s) => {
    const actions = s.spec.actions || {};
    // `units`: the files' moof+mdat units, appended in this order (indices,
    // 0 the init), as players that load a fragment again do.
    const fetched = async (file) => {
      // a+b: both in one append.
      const parts = await Promise.all(file.split('+').map(async (f) => new Uint8Array(await (await fetch(url(f))).arrayBuffer())));
      const data = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
      parts.reduce((at, p) => (data.set(p, at), at + p.length), 0);
      return data;
    };
    let appends = s.spec.files;
    let pieces = null;
    if (s.spec.units) {
      const all = units(await fetched(s.spec.files.join('+')));
      pieces = s.spec.units.map((i) => all[i]);
      appends = s.spec.units.map((i) => `unit ${i}`);
    }
    for (const [index, file] of appends.entries()) {
      const action = actions[index] || {};
      if (action.wait) {
        // With keepalive, as the shim's paused progressive downloads.
        const timer = action.keepalive && setInterval(() => conv.post({ type: 'keepalive', sb: s.id }), 100);
        await new Promise((r) => setTimeout(r, action.wait));
        clearInterval(timer);
      }
      if (action.drain) {
        // As before endOfStream(), and then the page carries on.
        const reply = await conv.drain(s.id);
        if (reply.type === 'error') fail(`drain: ${reply.message}`);
        else await deliver(s, 'drain', reply);
      }
      if (action.size) {
        conv.post({ type: 'size', sb: s.id, width: action.size[0], height: action.size[1], fps: action.size[2] || 0 });
      }
      let data = pieces ? pieces[index] : await fetched(file);
      if (action.patch) data = patch(data, action.patch);
      const step = s.spec.split || data.length;
      // A progressive file's appends say where they start, and go on from
      // `need` when a reply has one, as the shim's do.
      const progressive = s.spec.mime === 'progressive';
      for (let at = 0, next = 0; at < data.length; at = next) {
        next = at + step;
        const piece = data.slice(at, at + step);
        const size = piece.length;
        const t0 = performance.now();
        const replied = conv.append(s.id, piece.buffer, progressive ? at : undefined);
        if (action.abort) {
          // The page's abort(): the shim drops the reply and resets.
          conv.post({ type: 'reset', sb: s.id });
        }
        const reply = await Promise.race([replied, new Promise((r) => setTimeout(() => r(null), 20000))]);
        const took = performance.now() - t0;
        if (!reply) {
          fail(`${file}: no reply in 20 s`);
          return;
        }
        s.times.push({ file, bytes: size, ms: Math.round(took) });
        const held = (reply.held || []).map((g) => `${g.bytes.byteLength}@${g.seq}`).join(',');
        log(`  ${file} @${at}: ${reply.type} ${reply.bytes ? reply.bytes.byteLength : reply.message}` +
          `${held ? ' held ' + held : ''} in ${Math.round(took)} ms`);
        if (action.expect === 'error') {
          if (reply.type !== 'error') fail(`${file}: converted, expected an error`);
          continue;
        }
        if (reply.type === 'error') {
          fail(`${file}: ${reply.message}`);
          continue;
        }
        if (action.abort) continue;
        await deliver(s, file, reply);
        if (reply.need === undefined) continue;
        s.needs.push(reply.need);
        if (at + step < data.length) {
          // The append the shim sent before it heard: dropped, empty.
          const stale = await conv.append(s.id, data.slice(at + step, at + 2 * step).buffer, at + step);
          if (stale.type !== 'output' || stale.bytes.byteLength || stale.held) fail(`stale append at ${at + step} not dropped`);
          s.dropped++;
        }
        next = reply.need;
      }
    }
    if (!params.has('v1')) {
      const reply = await conv.drain(s.id);
      if (reply.type === 'error') fail(`drain: ${reply.message}`);
      else await deliver(s, 'drain', reply);
    }
  }));
  if (conv.fatal) fail('fatal: ' + conv.fatal);
  if (c.errorsOnly) {
    for (const s of states) conv.post({ type: 'close', sb: s.id });
    if (c.tune) conv.post({ type: 'tune', tune: {} });
    video.remove();
    return result;
  }
  if (ms.readyState === 'open' && !states.some((s) => s.sb && s.sb.updating)) ms.endOfStream();
  for (const s of states) conv.post({ type: 'close', sb: s.id });

  // Timeline: one range, where the input's is.
  for (const [i, s] of states.entries()) {
    const got = s.sb ? ranges(s.sb.buffered) : [];
    const want = (c.expected && c.expected[i]) || (expected && expected[i]);
    // Media appends only: the first is usually the init's.
    const media = s.times.filter((t) => !/init/.test(t.file));
    const info = {
      mime: s.mime,
      buffered: got,
      expected: want,
      appends: s.times,
      mediaMs: media.reduce((sum, t) => sum + t.ms, 0),
      held: s.helds,
      sizes: s.sizes,
    };
    result.sbs.push(info);
    if (want) {
      if (got.length !== 1) fail(`sb ${i}: ${got.length} buffered ranges`);
      else if (Math.abs(got[0][0] - want[0]) > 0.034 || Math.abs(got[0][1] - want[1]) > 0.05) {
        fail(`sb ${i}: buffered ${JSON.stringify(got[0])}, input ${JSON.stringify(want.map((x) => +x.toFixed(4)))}`);
      }
    } else if (!got.length) {
      fail(`sb ${i}: nothing buffered`);
    }
    info.naturals = s.naturals;
    info.needs = s.needs;
    if (s.spec.natural && JSON.stringify(s.natural) !== JSON.stringify(s.spec.natural)) {
      fail(`sb ${i}: natural size ${JSON.stringify(s.natural)}, expected ${JSON.stringify(s.spec.natural)}`);
    }
    // Every natural size change: [width, height, at] (null: at once).
    if (s.spec.naturals) {
      const ok = s.naturals.length === s.spec.naturals.length && s.naturals.every((n, k) => {
        const e = s.spec.naturals[k];
        return n[0] === e[0] && n[1] === e[1] && (e[2] === null ? n[2] === null : Math.abs(n[2] - e[2]) < 0.05);
      });
      if (!ok) fail(`sb ${i}: naturals ${JSON.stringify(s.naturals)}, expected ${JSON.stringify(s.spec.naturals)}`);
    }
    if (s.spec.needs !== undefined && s.needs.length !== s.spec.needs) {
      fail(`sb ${i}: ${s.needs.length} needs ${JSON.stringify(s.needs)}, expected ${s.spec.needs}`);
    }
    if (s.spec.lastSize) {
      const last = s.sizes[s.sizes.length - 1];
      if (!last || last[0] !== s.spec.lastSize[0] || last[1] !== s.spec.lastSize[1]) {
        fail(`sb ${i}: last init is ${JSON.stringify(last)}, expected ${JSON.stringify(s.spec.lastSize)}`);
      }
    }
    if (params.has('save')) {
      const all = new Blob(s.bytes);
      await fetch(`/save/${c.name}-${i}.mp4`, { method: 'POST', body: all });
    }
  }

  // Playback. A hidden tab pauses muted media, so this seeks through the
  // timeline and counts decoded frames and audio bytes; whether time moves
  // after play() is reported only.
  const hasVideo = states.some((s) => s.mime && s.mime.includes('vp09'));
  const hasAudio = states.some((s) => s.mime && s.mime.includes('flac'));
  const buffered = video.buffered;
  const from = buffered.length ? buffered.start(0) : 0;
  const to = buffered.length ? buffered.end(buffered.length - 1) : 0;
  const seeks = [];
  for (const at of [0.1, 0.5, 0.9]) {
    video.currentTime = from + (to - from) * at;
    await Promise.race([
      new Promise((r) => video.addEventListener('seeked', r, { once: true })),
      new Promise((r) => setTimeout(r, 3000)),
    ]);
    seeks.push({ at: +video.currentTime.toFixed(3), readyState: video.readyState, width: video.videoWidth });
    if (video.readyState < 2) fail(`readyState ${video.readyState} after seeking to ${video.currentTime.toFixed(2)}`);
  }
  // Muted media in a hidden tab doesn't play, but seeking prerolls audio.
  if (hasAudio && !(video.webkitAudioDecodedByteCount > 0)) fail('no audio decoded');
  try {
    await Promise.race([video.play(), new Promise((r) => setTimeout(r, 3000))]);
    await new Promise((r) => setTimeout(r, 1000));
  } catch (e) {
    // Expected in a hidden tab; reported, not failed.
  }
  const quality = video.getVideoPlaybackQuality();
  result.playback = {
    seeks,
    playing: !video.paused,
    currentTime: +video.currentTime.toFixed(3),
    videoWidth: video.videoWidth,
    videoHeight: video.videoHeight,
    decodedFrames: quality.totalVideoFrames,
    droppedFrames: quality.droppedVideoFrames,
    videoBytes: video.webkitVideoDecodedByteCount,
    audioBytes: video.webkitAudioDecodedByteCount,
  };
  if (hasVideo && !(video.videoWidth > 0 && quality.totalVideoFrames >= 3)) fail('video frames did not decode');

  // A/V start alignment, against the input's.
  if (states.length === 2 && expected) {
    const [a, b] = states.map((s) => s.sb.buffered.start(0));
    const drift = Math.abs((a - b) - (expected[0][0] - expected[1][0]));
    result.avStartDrift = +drift.toFixed(4);
    if (drift > 0.034) fail(`A/V starts drift by ${drift.toFixed(3)} s`);
  }
  // What the worker's codecs did for this case.
  const after = await conv.stats();
  result.worker = {};
  for (const key of Object.keys(after)) {
    if (typeof after[key] === 'number') result.worker[key] = after[key] - (before[key] || 0);
  }
  // Counters that have to have moved, such as {"recycled": 1}: at least,
  // or [least, most].
  for (const [key, want] of Object.entries(c.expectStats || {})) {
    const [least, most] = Array.isArray(want) ? want : [want, Infinity];
    const got = result.worker[key] || 0;
    if (!(got >= least && got <= most)) fail(`worker ${key} ${got}, expected ${JSON.stringify(want)}`);
  }
  if (c.tune) conv.post({ type: 'tune', tune: {} });
  video.pause();
  video.remove();
  return result;
}

async function main() {
  const cases = await (await fetch('/media/harness/cases.json')).json();
  const expected = await fetch('/out/expected.json').then((r) => (r.ok ? r.json() : {}));
  const t0 = performance.now();
  const conv = await startWorker();
  const readyMs = Math.round((await conv.ready) - t0);
  log('worker ready in', readyMs, 'ms');
  const only = params.get('case');
  const results = [];
  let sbBase = 1;
  // ?repeat=N runs the cases N times over, for timing.
  const runs = [];
  for (let i = 0; i < (Number(params.get('repeat')) || 1); i++) runs.push(...cases);
  for (const c of runs) {
    if (only && !only.split(',').includes(c.name)) continue;
    log('running', c.name);
    try {
      results.push(await runCase(conv, c, sbBase, expected[c.name]));
    } catch (e) {
      results.push({ name: c.name, ok: false, problems: [String(e && e.stack || e)] });
    }
    sbBase += c.sbs.length;
    const last = results[results.length - 1];
    log(last.ok ? 'ok' : 'FAILED', c.name, (last.problems || []).join('; '));
  }
  window.results = results;
  window.readyMs = readyMs;
  document.title = 'done';
}

main();
