// Runs each case in cases.json through worker.js in the real engine and
// appends the output to a real MediaSource, the way shim.js will. Results
// land in window.results; ?case=name runs one case, ?save=1 posts each
// SourceBuffer's converted bytes to serve.py for ffprobe.
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
    this.seq = 0;
    worker.onmessage = (e) => {
      const msg = e.data;
      const key = msg.sb + ':' + msg.seq;
      const done = this.waiting.get(key);
      this.waiting.delete(key);
      if (done) done(msg);
    };
  }

  open(sb, mime) {
    this.worker.postMessage({ type: 'open', sb, mime });
  }

  append(sb, bytes) {
    const seq = ++this.seq;
    return new Promise((resolve) => {
      this.waiting.set(sb + ':' + seq, resolve);
      this.worker.postMessage({ type: 'append', sb, seq, bytes }, [bytes]);
    });
  }
}

async function startWorker() {
  const [source, wasm] = await Promise.all([
    fetch('/shell/resources/media/worker.js').then((r) => r.text()),
    fetch('/media/target/wasm32-unknown-unknown/release/mbga_media.wasm').then((r) => r.arrayBuffer()),
  ]);
  const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
  const conv = new Converter(worker);
  // Like the shim: the module may come as bytes or compiled.
  worker.postMessage({ type: 'wasm', module: params.has('bytes') ? wasm : await WebAssembly.compile(wasm) });
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

async function runCase(conv, c, sbBase, expected) {
  const result = { name: c.name, ok: true, problems: [], sbs: [] };
  const fail = (msg) => {
    result.ok = false;
    result.problems.push(msg);
  };
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
    conv.open(id, spec.mime);
    const out = spec.mime === 'progressive' ? null : mapMime(spec.mime);
    return { spec, id, mime: out, sb: out ? ms.addSourceBuffer(out) : null, times: [], bytes: [] };
  });
  if (states.some((s) => !s.sb) && states.length > 1) throw new Error('one progressive SourceBuffer per case');

  await Promise.all(states.map(async (s) => {
    for (const file of s.spec.files) {
      let data = new Uint8Array(await (await fetch(url(file))).arrayBuffer());
      const step = s.spec.split || data.length;
      for (let at = 0; at < data.length; at += step) {
        const piece = data.slice(at, at + step);
        const size = piece.length;
        const t0 = performance.now();
        const reply = await conv.append(s.id, piece.buffer);
        const took = performance.now() - t0;
        s.times.push({ file, bytes: size, ms: Math.round(took) });
        log(`  ${file} @${at}: ${reply.type} ${reply.bytes ? reply.bytes.byteLength : reply.message} in ${Math.round(took)} ms`);
        if (reply.type === 'error') {
          fail(`${file}: ${reply.message}`);
          continue;
        }
        if (!s.sb && reply.mime) {
          s.mime = reply.mime;
          s.sb = ms.addSourceBuffer(reply.mime);
        }
        if (reply.bytes.byteLength) {
          s.bytes.push(new Uint8Array(reply.bytes));
          try {
            await appendTo(s.sb, reply.bytes);
          } catch (e) {
            fail(`${file}: ${e.message}`);
          }
        }
      }
    }
  }));
  if (ms.readyState === 'open' && !states.some((s) => s.sb && s.sb.updating)) ms.endOfStream();

  // Timeline: one range, where the input's is.
  for (const [i, s] of states.entries()) {
    const got = s.sb ? ranges(s.sb.buffered) : [];
    const want = expected && expected[i];
    const info = { mime: s.mime, buffered: got, expected: want, appends: s.times };
    result.sbs.push(info);
    if (want) {
      if (got.length !== 1) fail(`sb ${i}: ${got.length} buffered ranges`);
      else if (Math.abs(got[0][0] - want[0]) > 0.034 || Math.abs(got[0][1] - want[1]) > 0.05) {
        fail(`sb ${i}: buffered ${JSON.stringify(got[0])}, input ${JSON.stringify(want.map((x) => +x.toFixed(4)))}`);
      }
    } else if (!got.length) {
      fail(`sb ${i}: nothing buffered`);
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
    seeks.push({ at: +video.currentTime.toFixed(3), readyState: video.readyState });
    if (video.readyState < 2) fail(`readyState ${video.readyState} after seeking to ${video.currentTime.toFixed(2)}`);
  }
  // Muted media in a hidden tab doesn't play, but seeking prerolls audio.
  if (hasAudio && !(video.webkitAudioDecodedByteCount > 0)) fail('no audio decoded');
  try {
    await video.play();
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
  video.pause();
  video.remove();
  return result;
}

async function main() {
  const cases = await (await fetch('/media/harness/cases.json')).json();
  const expected = await fetch('/out/expected.json').then((r) => (r.ok ? r.json() : {}));
  const conv = await startWorker();
  const only = params.get('case');
  const results = [];
  let sbBase = 1;
  for (const c of cases) {
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
  document.title = 'done';
}

main();
