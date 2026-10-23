// Plays H.264 and AAC video, which this engine has no decoders for, by
// converting it in the page. The engine runs this in every frame and
// dedicated worker before the page's own scripts (MBEngine.mm, "media
// shim").
//
// Pages ask whether they can play H.264 (MediaSource.isTypeSupported,
// canPlayType, mediaCapabilities) and hear yes when a conversion would play.
// A SourceBuffer made for H.264 or AAC is a real one made for VP9 and FLAC;
// the bytes the page appends go to a worker (worker.js and mbga_media.wasm,
// from media/) and what comes back is appended instead, with the settings
// (timestampOffset, append window, mode) the page had when it appended. The
// page sees the SourceBuffer it expects: its updating flag, settings and
// events follow the page's appends, not the converted ones. A plain MP4 the
// engine refuses (X's GIFs) is fetched, converted the same way and played
// through a MediaSource on the same element.
//
// Conversion stays a little ahead of playback: an append whose
// SourceBuffer already holds plenty past the playhead waits, still
// updating, until the playhead gets closer. The worker also learns how big
// each video is shown, so it doesn't encode more pixels than that.
//
// Players that use MediaSource in a dedicated worker (Twitch's) get it there
// too. Such a worker asks the page that started it for the converter.
//
// Everything here runs in every frame of every page, so until a converted
// SourceBuffer or video appears it only answers questions: the worker, the
// converter and the SourceBuffer hooks come with the first one.
(function () {
  'use strict';
  var G = globalThis;
  var Media = G.HTMLMediaElement;
  var MS = G.MediaSource;
  var mark = Symbol.for('mbga.media');
  if (!MS || !G.SourceBuffer || MS[mark]) {
    return;
  }
  Object.defineProperty(MS, mark, { value: true });

  var isWindow = typeof G.Window === 'function' && G instanceof G.Window;
  // The page may replace any of these later.
  var debug = console.debug.bind(console);
  var NativeEvent = G.Event;
  var NativeWorker = G.Worker;
  // A worker's global scope gets its timers and postMessage() after this
  // runs, so those are looked up when used.
  var Channel = G.MessageChannel;
  var setTimer = function (f, delay) {
    return G.setTimeout(f, delay);
  };
  var clearTimer = function (id) {
    G.clearTimeout(id);
  };
  var defineProperty = Object.defineProperty;
  var getDescriptor = Object.getOwnPropertyDescriptor;
  var nativeGetAttribute = G.Element ? G.Element.prototype.getAttribute : null;
  var SB = G.SourceBuffer.prototype;
  var VP9 = 'vp09.00.41.08';
  var FLAC = 'flac';
  // Seconds converted ahead of the playhead, and before the first play.
  var LOOKAHEAD = 10;
  var STARTUP = 5;
  var RELAY = '__mbga_media_relay__';

  // ------------------------------------------------------------- patching

  // Replaces a method with |make(original)|, called as (self, args). A
  // proxy keeps the original's name, length and native-looking source.
  function hook(target, key, make) {
    var d = getDescriptor(target, key);
    if (!d || typeof d.value !== 'function') {
      return d && d.value;
    }
    var original = d.value;
    var impl = make(original);
    d.value = new Proxy(original, {
      apply: function (_, self, args) {
        return impl(self, args);
      },
    });
    defineProperty(target, key, d);
    return original;
  }

  // Replaces an accessor's getter or setter the same way; |make| gets the
  // original getter and setter.
  function hookAccessor(target, key, getter, setter) {
    var d = getDescriptor(target, key);
    if (!d || !d.get) {
      return null;
    }
    var original = { get: d.get, set: d.set };
    if (getter) {
      var get = getter(original);
      d.get = new Proxy(original.get, {
        apply: function (_, self) {
          return get(self);
        },
      });
    }
    if (setter && d.set) {
      var set = setter(original);
      d.set = new Proxy(original.set, {
        apply: function (_, self, args) {
          return set(self, args[0]);
        },
      });
    }
    defineProperty(target, key, d);
    return original;
  }

  function invalidState(what, property) {
    return new DOMException(
      (property ? 'Failed to set the \'' + what + '\' property on' : 'Failed to execute \'' + what + '\' on') +
      ' \'SourceBuffer\': This SourceBuffer is still processing an \'appendBuffer\' or \'remove\' ' +
      'operation.', 'InvalidStateError');
  }

  function notOpen(what, on) {
    return new DOMException('Failed to execute \'' + what + '\' on \'' + on + '\': The ' +
                            'MediaSource\'s readyState is not \'open\'.', 'InvalidStateError');
  }

  // Runs |f| in a task of its own, as the events MSE queues do. A message
  // port's tasks aren't throttled in background tabs, unlike timers.
  var tasks = null;
  var taskPort = null;
  function task(f) {
    if (!taskPort) {
      var channel = new Channel();
      tasks = [];
      channel.port1.onmessage = function () {
        var next = tasks.shift();
        if (next) {
          next();
        }
      };
      taskPort = channel.port2;
    }
    tasks.push(f);
    taskPort.postMessage(0);
  }

  // --------------------------------------------------------------- types

  // "video/mp4; codecs=..." split into its container and codecs, or null.
  function parse(type) {
    if (typeof type !== 'string') {
      return null;
    }
    var m = /^\s*((?:video|audio)\/mp4)\s*(?:;(.*))?$/i.exec(type);
    var c = m && /codecs\s*=\s*(?:"([^"]*)"|'([^']*)'|([^;\s]*))/i.exec(m[2] || '');
    if (!c) {
      return null;
    }
    var codecs = (c[1] || c[2] || c[3] || '').split(',').map(function (s) {
      return s.trim();
    }).filter(Boolean);
    return codecs.length ? { container: m[1].toLowerCase(), codecs: codecs } : null;
  }

  function isAvc(codec) {
    return /^avc[13](\.|$)/i.test(codec);
  }

  function isAac(codec) {
    return /^mp4a(\.|$)/i.test(codec);
  }

  // The type of the converted stream, or null when nothing needs converting.
  function mapType(type) {
    var t = parse(type);
    if (!t || !t.codecs.some(function (c) { return isAvc(c) || isAac(c); })) {
      return null;
    }
    return t.container + '; codecs="' + t.codecs.map(function (c) {
      return isAvc(c) ? VP9 : isAac(c) ? FLAC : c;
    }).join(',') + '"';
  }

  // Conversion keeps up with H.264 up to level 4.1 (1080p at 30 frames a
  // second) and AAC; above that players should pick a smaller rendition.
  function withinLimits(type) {
    return parse(type).codecs.every(function (c) {
      if (isAvc(c)) {
        var m = /^avc[13](?:\.[0-9a-f]{4}([0-9a-f]{2})|\.\d+\.(\d+))?$/i.exec(c);
        return !!m && (m[1] ? parseInt(m[1], 16) <= 0x29 : m[2] ? +m[2] <= 41 : true);
      }
      return !isAac(c) || /^mp4a\.40\.0?(2|5|29)$/i.test(c);
    });
  }

  var nativeIsTypeSupported = MS.isTypeSupported;
  function nativeSupports(type) {
    return nativeIsTypeSupported.call(MS, type);
  }

  // Whether |type| plays once converted and doesn't play without.
  function convertible(type) {
    // Looked up each time: a worker gets WebCodecs after this script runs.
    if (broken || typeof NativeWorker !== 'function' || typeof G.WebAssembly !== 'object' ||
        typeof G.VideoDecoder !== 'function') {
      return false;
    }
    try {
      var mapped = mapType(type);
      return !!mapped && withinLimits(type) && !nativeSupports(type) && nativeSupports(mapped) &&
        canCompile();
    } catch (e) {
      return false;
    }
  }

  // Whether the Content-Security-Policy here, which the converter's worker
  // inherits, lets WebAssembly compile. Checked once, with an empty module.
  var compiles = null;
  function canCompile() {
    if (compiles === null) {
      try {
        compiles = !!new WebAssembly.Module(new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
      } catch (e) {
        compiles = false;
      }
    }
    return compiles;
  }

  hook(MS, 'isTypeSupported', function (original) {
    return function (self, args) {
      return original.apply(self, args) || convertible(args[0]);
    };
  });

  hook(Media ? Media.prototype : {}, 'canPlayType', function (original) {
    return function (self, args) {
      var answer = original.apply(self, args);
      if (answer || !convertible(args[0])) {
        return answer;
      }
      return original.call(self, mapType(args[0]));
    };
  });

  // A copy of a mediaCapabilities configuration with converted types, or
  // null when there's nothing to convert or it can't be.
  function mapConfig(config) {
    if (!config || typeof config !== 'object' || config.keySystemConfiguration ||
        (config.type !== 'media-source' && config.type !== 'file')) {
      return null;
    }
    var copy = Object.assign({}, config);
    var changed = false;
    var ok = ['video', 'audio'].every(function (kind) {
      var part = config[kind];
      if (!part || !mapType(part.contentType)) {
        return true;
      }
      if (!convertible(part.contentType)) {
        return false;
      }
      copy[kind] = Object.assign({}, part, { contentType: mapType(part.contentType) });
      changed = true;
      return true;
    });
    return ok && changed ? copy : null;
  }

  var Capabilities = G.MediaCapabilities;
  if (Capabilities) {
    hook(Capabilities.prototype, 'decodingInfo', function (original) {
      return function (self, args) {
        var answer = original.apply(self, args);
        var mapped;
        try {
          mapped = mapConfig(args[0]);
        } catch (e) {}
        if (!mapped) {
          return answer;
        }
        return answer.then(function (info) {
          if (info.supported) {
            return info;
          }
          return original.call(self, mapped).then(function (converted) {
            if (!converted.supported) {
              return info;
            }
            return {
              supported: true,
              smooth: converted.smooth,
              powerEfficient: false,
              configuration: info.configuration,
              keySystemAccess: null,
            };
          }, function () {
            return info;
          });
        });
      };
    });
  }

  // ------------------------------------------------------------ converter

  // The converter's worker source and module (base64), kept a little while
  // for workers this frame starts that ask for it too.
  var codec = null;
  var codecDrop = 0;
  var codecWaiters = null;
  var token = '';

  function getCodec(callback) {
    if (codec) {
      callback(codec.source, codec.wasm);
      return;
    }
    if (codecWaiters) {
      codecWaiters.push(callback);
      return;
    }
    codecWaiters = [callback];
    var done = function (source, wasm) {
      var waiters = codecWaiters;
      codecWaiters = null;
      if (typeof source === 'string' && typeof wasm === 'string') {
        codec = { source: source, wasm: wasm };
        clearTimer(codecDrop);
        codecDrop = setTimer(function () {
          codec = null;
        }, 30000);
      }
      waiters.forEach(function (f) {
        f(source, wasm);
      });
    };
    var timeout = setTimer(function () {
      if (isWindow) {
        delete G.__mbgaCodecReady;
      }
      done(null, null);
    }, 15000);
    var ready = function (source, wasm) {
      clearTimer(timeout);
      done(source, wasm);
    };
    if (isWindow) {
      // The engine asks every frame of the tab who sent this; this
      // document answers through who() and gets the converter.
      var answer = function (source, wasm) {
        delete G.__mbgaCodecReady;
        ready(source, wasm);
      };
      token = token || Math.random().toString(36).slice(2);
      answer.who = function (frame) {
        debug(frame + ':' + token);
      };
      defineProperty(G, '__mbgaCodecReady', { configurable: true, value: answer });
      debug('__mbga_codec');
    } else {
      askParent(ready);
    }
  }

  // A worker asks whoever started it, over a channel of its own; sizes of
  // the video its MediaSource plays come the same way.
  var parentPort = null;
  var parentSize = null;
  function askParent(ready) {
    if (typeof G.postMessage !== 'function' || !Channel) {
      ready(null, null);
      return;
    }
    var channel = new Channel();
    parentPort = channel.port1;
    parentPort.onmessage = function (event) {
      var data = event.data || {};
      if (data.codec) {
        ready(data.source, data.wasm);
      } else if (data.size) {
        parentSize = [data.width, data.height];
        live.forEach(function (st) {
          sendSize(st, data.width, data.height);
        });
        // And on to this worker's own workers.
        sizeHandle(data.width, data.height);
      }
    };
    try {
      G.postMessage({ [RELAY]: 1 }, [channel.port2]);
    } catch (e) {
      ready(null, null);
    }
  }

  // Workers this context starts: their requests for the converter are
  // answered here and never reach the page.
  var children = [];
  function relay(event) {
    var data = event.data;
    if (!data || data[RELAY] !== 1 || !event.ports || !event.ports[0]) {
      return;
    }
    event.stopImmediatePropagation();
    var port = event.ports[0];
    children.push(port);
    if (handleSize) {
      port.postMessage({ size: 1, width: handleSize[0], height: handleSize[1] });
    }
    getCodec(function (source, wasm) {
      port.postMessage({ codec: 1, source: source, wasm: wasm });
    });
  }

  if (NativeWorker) {
    defineProperty(G, 'Worker', {
      configurable: true,
      writable: true,
      value: new Proxy(NativeWorker, {
        construct: function (target, args, newTarget) {
          var worker = Reflect.construct(target, args, newTarget);
          worker.addEventListener('message', relay);
          return worker;
        },
      }),
    });
  }

  // One converter worker per frame or worker, started with the first
  // conversion and shared.
  var worker = null;
  var starting = false;
  var broken = false;
  var heard = false;
  var silence = 0;
  var outbox = [];
  var nextId = 0;
  // Conversions by id: {reply(data), fail(message)}.
  var conversions = {};

  function post(message, transfer) {
    if (broken) {
      // Appends and drains still get their answer, an error.
      if (message.type === 'append' || message.type === 'drain') {
        task(function () {
          var conversion = conversions[message.sb];
          if (conversion) {
            conversion.reply({ type: 'error', sb: message.sb, seq: message.seq,
                               message: 'the converter is not available' });
          }
        });
      }
      return;
    }
    if ((message.type === 'append' || message.type === 'drain') && !heard && !silence) {
      // Until the worker first answers: one that never starts mustn't
      // leave players waiting.
      silence = setTimer(function () {
        fail('the converter did not start');
      }, 10000);
    }
    if (worker) {
      worker.postMessage(message, transfer || []);
      return;
    }
    outbox.push([message, transfer]);
    startWorker();
  }

  function startWorker() {
    if (starting || broken) {
      return;
    }
    starting = true;
    getCodec(begin);
  }

  function decodeBase64(text) {
    if (Uint8Array.fromBase64) {
      return Uint8Array.fromBase64(text);
    }
    var binary = atob(text);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  function begin(source, wasm) {
    if (broken) {
      return;
    }
    if (typeof source !== 'string' || typeof wasm !== 'string') {
      fail('the engine did not send the converter');
      return;
    }
    var url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    var revoke = function () {
      if (url) {
        URL.revokeObjectURL(url);
        url = null;
      }
    };
    try {
      // The page's Content-Security-Policy may forbid blob: workers. The
      // engine knows this worker by its name and leaves it alone.
      worker = new NativeWorker(url, { name: 'MBGA video converter' });
    } catch (e) {
      revoke();
      fail('this site does not allow the converter to start');
      return;
    }
    worker.onmessage = function (event) {
      revoke();
      var data = event.data;
      if (!heard) {
        heard = true;
        clearTimer(silence);
      }
      if (!data) {
        return;
      }
      if (data.type === 'fatal') {
        fail(String(data.message));
        return;
      }
      var conversion = conversions[data.sb];
      if (conversion && (data.type === 'output' || data.type === 'error')) {
        conversion.reply(data);
      }
    };
    worker.onerror = function (event) {
      event.preventDefault();
      revoke();
      fail(event.message || 'the converter stopped');
    };
    var bytes = decodeBase64(wasm);
    worker.postMessage({ type: 'wasm', module: bytes.buffer }, [bytes.buffer]);
    var queued = outbox;
    outbox = [];
    queued.forEach(function (item) {
      worker.postMessage(item[0], item[1] || []);
    });
  }

  // Without a converter every conversion in flight, and every later one,
  // fails as a decode error would, and players can pick something else.
  function fail(message) {
    if (broken) {
      return;
    }
    broken = true;
    clearTimer(silence);
    if (worker) {
      worker.terminate();
      worker = null;
    }
    outbox = [];
    debug('MBGA could not convert video: ' + message);
    Object.keys(conversions).forEach(function (id) {
      var conversion = conversions[id];
      if (conversion) {
        conversion.fail(message);
      }
    });
  }

  function register(conversion) {
    var id = ++nextId;
    conversions[id] = conversion;
    return id;
  }

  // --------------------------------------------------------- display size

  // How big each converted video is shown, in device pixels, so the worker
  // can encode no bigger. Elements are found through the blob: URL of their
  // MediaSource, or the handle of one in a worker.
  var msUrls = new WeakMap();
  var urlElements = new Map();
  var sized = new WeakMap();
  var resizer = null;
  var handleSize = null;

  if (isWindow && Media) {
    hook(URL, 'createObjectURL', function (original) {
      return function (self, args) {
        var url = original.apply(self, args);
        if (args[0] instanceof MS) {
          msUrls.set(args[0], url);
        }
        return url;
      };
    });
  }

  function elementOf(ms) {
    var url = msUrls.get(ms);
    if (!url || !isWindow) {
      return null;
    }
    var ref = urlElements.get(url);
    var el = ref && ref.deref();
    if (el) {
      return el;
    }
    var all = document.querySelectorAll('video,audio');
    for (var i = 0; i < all.length; i++) {
      if (nativeGetAttribute.call(all[i], 'src') === url) {
        return all[i];
      }
    }
    return null;
  }

  // Calls |update(width, height)| now and whenever |el| is shown at another
  // size, at most every half second, until it returns false.
  function watchSize(el, update) {
    if (!G.ResizeObserver || !el) {
      return;
    }
    var entry = sized.get(el);
    if (!entry) {
      entry = { updates: [], timer: 0, size: null, sent: false };
      sized.set(el, entry);
      resizer = resizer || new ResizeObserver(resized);
      resizer.observe(el, { box: 'device-pixel-content-box' });
    }
    if (entry.updates.indexOf(update) < 0) {
      entry.updates.push(update);
    }
    if (entry.size && update(entry.size[0], entry.size[1]) === false) {
      entry.updates.splice(entry.updates.indexOf(update), 1);
    }
  }

  function resized(entries) {
    entries.forEach(function (e) {
      var box = e.devicePixelContentBoxSize && e.devicePixelContentBoxSize[0];
      var el = e.target;
      var entry = sized.get(el);
      if (!entry || !box) {
        return;
      }
      entry.size = [Math.round(box.inlineSize), Math.round(box.blockSize)];
      if (entry.timer) {
        return;
      }
      entry.timer = setTimer(function () {
        entry.timer = 0;
        entry.updates = entry.updates.filter(function (f) {
          return f(entry.size[0], entry.size[1]) !== false;
        });
        if (!entry.updates.length) {
          resizer.unobserve(el);
          sized.delete(el);
        }
      }, entry.sent ? 500 : 0);
      entry.sent = true;
    });
  }

  // Sizes of videos played from a MediaSource in a worker go to the
  // workers this frame started.
  function sizeHandle(width, height) {
    handleSize = [width, height];
    children.forEach(function (port) {
      port.postMessage({ size: 1, width: width, height: height });
    });
  }

  function sendSize(st, width, height) {
    if (!st.video || st.dead || !(width > 0) || !(height > 0) ||
        (st.size && st.size[0] === width && st.size[1] === height)) {
      return;
    }
    st.size = [width, height];
    post({ type: 'size', sb: st.id, width: width, height: height });
  }

  // ------------------------------------------------------- SourceBuffers

  // State of each converted SourceBuffer:
  //   op: the page's append in progress: {seq, snap, bytes, sent,
  //       received, started}; snap is the settings it was made with.
  //   drain: {seq, received}: frames the worker holds, asked for before
  //       endOfStream().
  //   chunks: converted bytes the real SourceBuffer is still to get, each
  //       {bytes, snap}; current: the one it's appending now.
  //   page: the settings the page sees, which the real SourceBuffer has
  //       whenever it isn't appending.
  //   last: the snapshot of the last append, for its frames the worker
  //       hands back late (held).
  //   carry: chunks of appends the page saw finish didn't fit; the page
  //       hears QuotaExceededError at its next append until they do.
  var states = new WeakMap();
  // Per MediaSource: {ms, list: its converted SourceBuffers, el, eos}.
  var sources = new WeakMap();
  // The MediaSource of every SourceBuffer made since this frame started.
  var owners = new WeakMap();
  var live = new Set();
  var native = {};
  var EVENTS = ['updatestart', 'update', 'updateend', 'abort', 'error'];
  var SETTINGS = ['mode', 'appendWindowStart', 'appendWindowEnd', 'timestampOffset'];

  native.addSourceBuffer = hook(MS.prototype, 'addSourceBuffer', function (original) {
    return function (self, args) {
      var type = args[0];
      if (!convertible(type)) {
        var plain = original.apply(self, args);
        owners.set(plain, self);
        return plain;
      }
      var sb = original.call(self, mapType(type));
      owners.set(sb, self);
      adopt(self, sb, type);
      return sb;
    };
  });

  // A SourceBuffer switching to H.264 starts converting; one switching to
  // something the engine plays stops.
  native.changeType = hook(SB, 'changeType', function (original) {
    return function (self, args) {
      var st = states.get(self);
      var type = args[0];
      if (st && st.convert && updating(st)) {
        throw invalidState('changeType');
      }
      if (!convertible(type)) {
        original.apply(self, args);
        if (st && st.convert) {
          reopen(st);
          st.convert = false;
          dropOutput(st);
          restore(st);
          live.delete(st);
          post({ type: 'close', sb: st.id });
        }
        return;
      }
      if (st && st.convert) {
        // Converting already: the frames the worker holds go in first, as
        // the old type, then the real SourceBuffer changes.
        reopen(st);
        if (st.held) {
          drainNow(st, mapType(type));
        } else {
          st.chunks.push({ change: mapType(type) });
          pump(st);
        }
        st.video = mapType(type).indexOf(VP9) >= 0;
        st.size = null;
        post({ type: 'open', sb: st.id, mime: type });
        sizeFor(st);
        return;
      }
      original.call(self, mapType(type));
      if (!st) {
        var ms = owners.get(self);
        if (ms) {
          adopt(ms, self, type);
        }
        return;
      }
      st.convert = true;
      st.video = mapType(type).indexOf(VP9) >= 0;
      st.page = read(st.sb);
      st.size = null;
      live.add(st);
      post({ type: 'open', sb: st.id, mime: type });
      sizeFor(st);
    };
  });

  function read(sb) {
    var values = {};
    SETTINGS.forEach(function (key) {
      values[key] = native[key].get.call(sb);
    });
    return values;
  }

  function adopt(ms, sb, type) {
    installSourceBufferHooks();
    var st = {
      ms: ms, sb: sb, id: 0, seq: 0, convert: true, dead: false, firing: 0,
      video: mapType(type).indexOf(VP9) >= 0, size: null,
      op: null, drain: null, chunks: [], current: null, reopening: false,
      removing: false, queuedRemove: null, quota: 0, carry: false, retry: 0,
      page: read(sb), last: null, held: false,
    };
    st.last = st.page;
    st.id = register({
      reply: function (data) {
        reply(st, data);
      },
      fail: function (message) {
        if (st.op || st.drain) {
          failAppend(st, message);
        }
      },
    });
    states.set(sb, st);
    live.add(st);
    var source = sources.get(ms);
    if (!source) {
      source = { ms: ms, list: [], el: elementOf(ms), eos: null, watching: null };
      sources.set(ms, source);
      ms.addEventListener('sourceclose', function () {
        source.list.slice().forEach(close);
        source.eos = null;
        if (source.watching) {
          source.watching.abort();
          source.watching = null;
        }
      });
    }
    source.list.push(st);
    // Ahead of the page's listeners: the real SourceBuffer's events while
    // converted bytes go in are the shim's, and the page gets its own.
    EVENTS.forEach(function (name) {
      sb.addEventListener(name, function (event) {
        guard(st, event);
      });
    });
    post({ type: 'open', sb: st.id, mime: type });
    sizeFor(st);
  }

  function sizeFor(st) {
    if (!st.video) {
      return;
    }
    var source = sources.get(st.ms);
    if (source && source.el) {
      watchSize(source.el, function (width, height) {
        sendSize(st, width, height);
        return !st.dead;
      });
    } else if (parentSize) {
      sendSize(st, parentSize[0], parentSize[1]);
    }
  }

  function close(st) {
    if (st.dead) {
      return;
    }
    st.dead = true;
    dropOutput(st);
    st.op = null;
    st.queuedRemove = null;
    clearTimer(st.retry);
    live.delete(st);
    post({ type: 'close', sb: st.id });
    delete conversions[st.id];
    var source = sources.get(st.ms);
    if (source) {
      source.list = source.list.filter(function (s) {
        return s !== st;
      });
      endIfDone(source);
    }
  }

  function dropOutput(st) {
    st.chunks = [];
    st.current = null;
    st.drain = null;
    st.carry = false;
    st.quota = 0;
    st.held = false;
  }

  function fire(st, name) {
    st.firing++;
    try {
      st.sb.dispatchEvent(new NativeEvent(name));
    } finally {
      st.firing--;
    }
  }

  function realUpdating(st) {
    return native.updating.get.call(st.sb);
  }

  // What the page sees as updating.
  function updating(st) {
    return !!(st.op || st.queuedRemove || st.removing);
  }

  // Whether the real SourceBuffer is busy with the shim's own appends.
  function busy(st) {
    return !!(st.current || st.reopening) || realUpdating(st);
  }

  // Sets the real SourceBuffer's settings to |snap|'s. Only what differs:
  // setting mode or timestampOffset has side effects in sequence mode.
  function apply(st, snap) {
    var sb = st.sb;
    if (native.mode.get.call(sb) !== snap.mode) {
      native.mode.set.call(sb, snap.mode);
    }
    var start = snap.appendWindowStart;
    var end = snap.appendWindowEnd;
    if (start >= native.appendWindowEnd.get.call(sb)) {
      native.appendWindowEnd.set.call(sb, end);
    }
    if (native.appendWindowStart.get.call(sb) !== start) {
      native.appendWindowStart.set.call(sb, start);
    }
    if (native.appendWindowEnd.get.call(sb) !== end) {
      native.appendWindowEnd.set.call(sb, end);
    }
    if (native.timestampOffset.get.call(sb) !== snap.timestampOffset) {
      native.timestampOffset.set.call(sb, snap.timestampOffset);
    }
  }

  function restore(st) {
    if (st.dead || realUpdating(st)) {
      return;
    }
    try {
      apply(st, st.page);
    } catch (e) {}
  }

  function guard(st, event) {
    if (st.firing || !st.convert) {
      return;
    }
    if (st.removing) {
      // The page's own remove(): its events are the page's.
      if (event.type === 'updateend') {
        st.removing = false;
        task(function () {
          pump(st);
        });
      }
      return;
    }
    event.stopImmediatePropagation();
    if (st.dead) {
      return;
    }
    if (event.type === 'error') {
      if (st.current) {
        st.current.failed = true;
      }
      return;
    }
    // An updateend left over from an abort() comes while the real
    // SourceBuffer is busy again; only a real end counts.
    if (event.type !== 'updateend' || realUpdating(st)) {
      return;
    }
    if (st.reopening) {
      st.reopening = false;
      pump(st);
      return;
    }
    var chunk = st.current;
    if (!chunk) {
      return;
    }
    st.current = null;
    if (chunk.failed) {
      failAppend(st, 'the engine could not play the converted video');
      return;
    }
    if (chunk.snap.mode === 'sequence') {
      // Sequence mode moves timestampOffset along with what went in.
      chunk.snap.timestampOffset = native.timestampOffset.get.call(st.sb);
    }
    pump(st);
  }

  function reply(st, data) {
    if (st.dead || !st.convert) {
      return;
    }
    var op = st.op;
    var drain = st.drain;
    if (data.type === 'error') {
      if (op && data.seq === op.seq) {
        failAppend(st, String(data.message));
      } else if (drain && data.seq === drain.seq) {
        // The stream goes on without the frames the worker held.
        debug('MBGA could not convert video: ' + data.message);
        drained(st, drain);
      }
      return;
    }
    var mine = op && data.seq === op.seq;
    if (!mine && !(drain && data.seq === drain.seq)) {
      // For an append the page aborted.
      return;
    }
    if (data.held && data.held.byteLength) {
      st.chunks.push({ bytes: data.held, snap: st.last });
    }
    if (data.bytes && data.bytes.byteLength) {
      st.chunks.push({ bytes: data.bytes, snap: mine ? op.snap : st.last });
    }
    if (!mine && drain.change) {
      st.chunks.push({ change: drain.change });
    }
    if (mine) {
      op.received = true;
      st.last = op.snap;
      st.held = st.video;
    } else {
      drain.received = true;
      st.held = false;
    }
    pump(st);
  }

  // Moves things along: the page's remove() once the shim's appends are
  // done, converted bytes in, then the end of the page's append or drain.
  function pump(st) {
    if (st.dead || !st.convert || busy(st) || st.removing) {
      return;
    }
    if (st.queuedRemove) {
      var range = st.queuedRemove;
      st.queuedRemove = null;
      restore(st);
      try {
        native.remove.call(st.sb, range[0], range[1]);
        st.removing = true;
      } catch (e) {
        task(function () {
          fire(st, 'updateend');
        });
      }
      return;
    }
    while (st.chunks.length && st.chunks[0].change) {
      try {
        native.changeType.call(st.sb, st.chunks.shift().change);
      } catch (e) {
        failAppend(st, e.message);
        return;
      }
    }
    if (st.chunks.length) {
      var chunk = st.chunks[0];
      try {
        apply(st, chunk.snap);
        native.appendBuffer.call(st.sb, chunk.bytes);
      } catch (e) {
        if (e.name === 'QuotaExceededError') {
          noRoom(st);
        } else {
          failAppend(st, e.message);
        }
        return;
      }
      st.chunks.shift();
      st.current = chunk;
      st.quota = 0;
      return;
    }
    restore(st);
    st.carry = false;
    if (st.op && st.op.received) {
      complete(st, st.op);
    }
    if (st.drain && st.drain.received) {
      st.drain = null;
    }
    endIfDone(sources.get(st.ms));
  }

  // The real SourceBuffer is full. While the video plays, room is made as
  // the playhead moves on (the engine evicts what's behind it at each
  // append), so the page's append waits. Paused, or after a while, the
  // append ends as the page expects and the bytes wait: the page hears
  // QuotaExceededError at its next append, as it would have at this one,
  // and makes room.
  function noRoom(st) {
    restore(st);
    var now = Date.now();
    st.quota = st.quota || now;
    var source = sources.get(st.ms);
    var el = source && source.el;
    var playing = el && !el.paused;
    if (st.op && st.op.received && (!playing || now - st.quota > 5000)) {
      st.carry = true;
      complete(st, st.op);
    }
    // Tried again as the playhead moves, or every second without an
    // element to follow (in a worker).
    if (el) {
      watch(source);
    } else {
      clearTimer(st.retry);
      st.retry = setTimer(function () {
        pump(st);
      }, 1000);
    }
  }

  function complete(st, op) {
    if (st.op !== op) {
      return;
    }
    st.op = null;
    if (op.snap.mode === 'sequence') {
      st.page.timestampOffset = op.snap.timestampOffset;
    }
    start(op, st);
    fire(st, 'update');
    fire(st, 'updateend');
  }

  function start(op, st) {
    if (!op.started) {
      op.started = true;
      fire(st, 'updatestart');
    }
  }

  // An append that can't be converted ends as one the engine can't decode:
  // error, updateend, then the stream ends with a decode error.
  function failAppend(st, message) {
    debug('MBGA could not convert video: ' + message);
    var op = st.op;
    var source = sources.get(st.ms);
    dropOutput(st);
    st.op = null;
    if (source) {
      source.eos = null;
    }
    if (op) {
      start(op, st);
      fire(st, 'error');
      fire(st, 'updateend');
    }
    if (st.dead) {
      return;
    }
    try {
      if (realUpdating(st)) {
        native.abort.call(st.sb);
      }
    } catch (e) {}
    endWithError(st.ms, 0);
  }

  // endOfStream('decode'), once no other SourceBuffer is busy.
  function endWithError(ms, tries) {
    try {
      native.endOfStream.call(ms, 'decode');
    } catch (e) {
      if (readyState(ms) === 'open' && tries < 50) {
        setTimer(function () {
          endWithError(ms, tries + 1);
        }, 100);
      }
    }
  }

  // How far the real SourceBuffer holds media past the playhead, when its
  // element is known.
  function ahead(st, el) {
    try {
      var ranges = st.sb.buffered;
      var now = el.currentTime;
      for (var i = 0; i < ranges.length; i++) {
        if (ranges.start(i) <= now + 0.5 && ranges.end(i) > now) {
          return ranges.end(i) - now;
        }
      }
    } catch (e) {}
    return 0;
  }

  // Sends the page's append to the worker, unless the SourceBuffer holds
  // plenty past the playhead: then it waits, still updating, until the
  // playhead gets closer or moves.
  function dispatch(st) {
    var op = st.op;
    if (!op || op.sent || st.dead) {
      return;
    }
    var source = sources.get(st.ms);
    var el = source && source.el;
    if (el && !broken && !el.seeking) {
      var limit = el.played.length ? LOOKAHEAD : STARTUP;
      if (ahead(st, el) > limit) {
        watch(source);
        return;
      }
    }
    op.sent = true;
    var bytes = op.bytes;
    op.bytes = null;
    post({ type: 'append', sb: st.id, seq: op.seq, bytes: bytes }, [bytes]);
  }

  // Follows the element's playhead while appends wait for it or for room.
  function watch(source) {
    if (source.watching || !source.el) {
      return;
    }
    source.watching = new AbortController();
    var check = function () {
      source.list.forEach(function (st) {
        dispatch(st);
        if (st.chunks.length && !busy(st)) {
          pump(st);
        }
      });
    };
    ['timeupdate', 'seeking', 'play', 'ratechange', 'waiting'].forEach(function (name) {
      source.el.addEventListener(name, check, { signal: source.watching.signal });
    });
  }

  // A MediaSource the page sees as ended opens again when the page appends,
  // removes or changes settings, as MSE does.
  function reopen(st) {
    var source = sources.get(st.ms);
    if (source && source.eos) {
      source.eos = null;
      task(function () {
        st.ms.dispatchEvent(new NativeEvent('sourceopen'));
      });
    }
  }

  // Asks the worker for the frames it holds (before endOfStream() and
  // changeType()); |change| is the type the real SourceBuffer takes after.
  function drainNow(st, change) {
    var drain = { seq: ++st.seq, received: false, change: change };
    st.held = false;
    st.drain = drain;
    post({ type: 'drain', sb: st.id, seq: drain.seq });
    // Without an answer, things go on without those frames.
    setTimer(function () {
      if (st.drain === drain && !drain.received) {
        drained(st, drain);
      }
    }, 5000);
  }

  function drained(st, drain) {
    st.drain = null;
    if (drain.change) {
      st.chunks.push({ change: drain.change });
    }
    pump(st);
  }

  // endOfStream() once the converted SourceBuffers have everything.
  function endIfDone(source) {
    var eos = source && source.eos;
    if (!eos || source.list.some(function (st) {
      return st.convert && (st.drain || st.chunks.length || busy(st) || updating(st));
    })) {
      return;
    }
    source.eos = null;
    try {
      native.endOfStream.apply(source.ms, eos);
    } catch (e) {}
  }

  function copyBytes(data) {
    if (data instanceof ArrayBuffer) {
      return data.slice(0);
    }
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice().buffer;
  }

  var hooked = false;
  function installSourceBufferHooks() {
    if (hooked) {
      return;
    }
    hooked = true;
    native.updating = hookAccessor(SB, 'updating', function (original) {
      return function (self) {
        var st = states.get(self);
        return st && st.convert ? updating(st) : original.get.call(self);
      };
    });
    SETTINGS.forEach(function (key) {
      native[key] = hookAccessor(SB, key, function (original) {
        return function (self) {
          var st = states.get(self);
          return st && st.convert && !st.dead ? st.page[key] : original.get.call(self);
        };
      }, function (original) {
        return function (self, value) {
          var st = states.get(self);
          if (!st || !st.convert || st.dead) {
            return original.set.call(self, value);
          }
          if (updating(st)) {
            throw invalidState(key, true);
          }
          if (key === 'mode' || key === 'timestampOffset') {
            reopen(st);
          }
          if (busy(st)) {
            // The shim's own bytes are going in: the setting waits for them.
            st.page[key] = check(key, value, st.page);
            return;
          }
          original.set.call(self, value);
          st.page[key] = original.get.call(self);
        };
      });
    });

    native.appendBuffer = hook(SB, 'appendBuffer', function (original) {
      return function (self, args) {
        var st = states.get(self);
        var data = args[0];
        if (!st || !st.convert || st.dead ||
            !(data instanceof ArrayBuffer || ArrayBuffer.isView(data))) {
          // Not converted, or the native call throws the right error.
          return original.apply(self, args);
        }
        if (updating(st)) {
          throw invalidState('appendBuffer');
        }
        reopen(st);
        if (readyState(st.ms) === 'ended' && !busy(st)) {
          // Ended for real: an empty append opens the MediaSource again
          // now, as the page's own would.
          original.call(self, new ArrayBuffer(0));
          st.reopening = true;
        }
        if (st.carry && st.chunks.length && !busy(st)) {
          // What didn't fit goes first; until it does, the page hears
          // QuotaExceededError and nothing is lost.
          var chunk = st.chunks[0];
          try {
            apply(st, chunk.snap);
            original.call(self, chunk.bytes);
          } catch (e) {
            restore(st);
            throw e;
          }
          st.chunks.shift();
          st.current = chunk;
        }
        st.carry = false;
        var op = {
          seq: ++st.seq, snap: Object.assign({}, st.page), bytes: copyBytes(data),
          sent: false, received: false, started: false,
        };
        st.op = op;
        task(function () {
          start(op, st);
        });
        dispatch(st);
      };
    });

    native.abort = hook(SB, 'abort', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert || st.dead) {
          return original.apply(self, args);
        }
        var source = sources.get(st.ms);
        if (source && source.eos) {
          throw notOpen('abort', 'SourceBuffer');
        }
        if (st.queuedRemove) {
          throw new DOMException('Failed to execute \'abort\' on \'SourceBuffer\': ' +
                                 'Aborting asynchronous remove() operation is disallowed.',
                                 'InvalidStateError');
        }
        original.apply(self, args);
        var had = st.op;
        st.op = null;
        // The worker starts over; what it hasn't given back is dropped, as
        // the page asked.
        dropOutput(st);
        st.reopening = false;
        st.page.appendWindowStart = 0;
        st.page.appendWindowEnd = Infinity;
        restore(st);
        post({ type: 'reset', sb: st.id });
        if (had) {
          task(function () {
            start(had, st);
            fire(st, 'abort');
          });
          task(function () {
            fire(st, 'updateend');
          });
        }
      };
    });

    native.remove = hook(SB, 'remove', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert || st.dead) {
          return original.apply(self, args);
        }
        if (updating(st)) {
          throw invalidState('remove');
        }
        reopen(st);
        if (busy(st)) {
          var from = Number(args[0]);
          var to = Number(args[1]);
          if (!(from >= 0) || !(to > from)) {
            throw new TypeError('Failed to execute \'remove\' on \'SourceBuffer\': ' +
                                'The start provided (' + args[0] + ') is outside the range.');
          }
          st.queuedRemove = [from, to];
          return;
        }
        original.apply(self, args);
        st.removing = true;
      };
    });

    // endOfStream() waits for the frames the worker still holds and the
    // converted bytes still going in, or the stream would end short. The
    // page sees "ended" at once, and sourceended when it really is.
    native.endOfStream = hook(MS.prototype, 'endOfStream', function (original) {
      return function (self, args) {
        var source = sources.get(self);
        if (!source || !source.list.length) {
          return original.apply(self, args);
        }
        if (source.eos) {
          throw notOpen('endOfStream', 'MediaSource');
        }
        if (source.list.some(function (st) {
          return st.convert && updating(st);
        })) {
          throw new DOMException('Failed to execute \'endOfStream\' on \'MediaSource\': The ' +
                                 '\'updating\' attribute is true on one or more of this ' +
                                 'MediaSource\'s SourceBuffers.', 'InvalidStateError');
        }
        if (args[0] !== undefined) {
          // An error: nothing more is coming.
          source.list.forEach(function (st) {
            dropOutput(st);
            if (st.convert && realUpdating(st)) {
              native.abort.call(st.sb);
            }
          });
          return original.apply(self, args);
        }
        var waiting = source.list.filter(function (st) {
          return st.convert && (st.held || st.drain || st.chunks.length || busy(st));
        });
        if (readyState(self) !== 'open' || !waiting.length) {
          return original.apply(self, args);
        }
        source.eos = [];
        waiting.forEach(function (st) {
          if (st.held && !st.drain) {
            drainNow(st, null);
          } else {
            pump(st);
          }
        });
      };
    });

    native.readyState = hookAccessor(MS.prototype, 'readyState', function (original) {
      return function (self) {
        var state = original.get.call(self);
        var source = sources.get(self);
        return source && source.eos && state === 'open' ? 'ended' : state;
      };
    });

    hookAccessor(MS.prototype, 'duration', null, function (original) {
      return function (self, value) {
        var source = sources.get(self);
        if (source && source.eos) {
          throw new DOMException('Failed to set the \'duration\' property on \'MediaSource\': ' +
                                 'The MediaSource\'s readyState is not \'open\'.', 'InvalidStateError');
        }
        if (source && source.list.some(function (st) {
          return st.convert && updating(st);
        })) {
          throw new DOMException('Failed to set the \'duration\' property on \'MediaSource\': ' +
                                 'The \'updating\' attribute is true on one or more of this ' +
                                 'MediaSource\'s SourceBuffers.', 'InvalidStateError');
        }
        return original.set.call(self, value);
      };
    });

    hook(MS.prototype, 'removeSourceBuffer', function (original) {
      return function (self, args) {
        var st = states.get(args[0]);
        var had = st && st.convert && st.op;
        var result = original.apply(self, args);
        if (st) {
          close(st);
          if (had) {
            task(function () {
              start(had, st);
              fire(st, 'abort');
            });
            task(function () {
              fire(st, 'updateend');
            });
          }
        }
        return result;
      };
    });
  }

  function readyState(ms) {
    return native.readyState ? native.readyState.get.call(ms) : ms.readyState;
  }

  // A setting checked as the native setter would, for when it can't be
  // set yet.
  function check(key, value, page) {
    if (key === 'mode') {
      return value === 'segments' || value === 'sequence' ? value : page.mode;
    }
    var number = Number(value);
    var bad = key === 'appendWindowEnd'
      ? isNaN(number) || number <= page.appendWindowStart
      : !isFinite(number) || (key === 'appendWindowStart' && (number < 0 || number >= page.appendWindowEnd));
    if (bad) {
      throw new TypeError('Failed to set the \'' + key + '\' property on \'SourceBuffer\': ' +
                          'The value provided (' + value + ') is outside the range.');
    }
    return number;
  }

  // ------------------------------------------------------ plain MP4 files
  // Workers get the shim without this last section (WorkerShimParams() in
  // MBEngine.mm cuts it at the line above).

  if (Media && isWindow) {
    playPlainFiles();
  }

  function playPlainFiles() {

    // Elements whose MP4 is being converted, with the job doing it.
    var jobs = new WeakMap();
    var anyJob = false;
    var mediaHooked = false;
    var element = {};
    // pause() calls per element, so a play() the shim retries isn't one the
    // page took back.
    var pauses = new WeakMap();
    // Per element: the converted stream's blob: URL and the file's.
    var blobs = new WeakMap();
    var proto = Media.prototype;
    element.error = getDescriptor(proto, 'error');
    element.currentSrc = getDescriptor(proto, 'currentSrc');

    // The element's src setter tells which element a MediaSource plays on;
    // set by the page, it also ends a conversion.
    element.src = hookAccessor(proto, 'src', function (original) {
      return function (self) {
        var job = anyJob && active(self);
        return job && job.ms ? job.src : original.get.call(self);
      };
    }, function (original) {
      return function (self, value) {
        if (anyJob) {
          cancel(jobs.get(self));
        }
        if (typeof value === 'string' && value.lastIndexOf('blob:', 0) === 0) {
          urlElements.set(value, new WeakRef(self));
          if (urlElements.size > 32) {
            urlElements.delete(urlElements.keys().next().value);
          }
        }
        return original.set.call(self, value);
      };
    });

    hookAccessor(proto, 'srcObject', null, function (original) {
      return function (self, value) {
        if (anyJob) {
          cancel(jobs.get(self));
        }
        if (G.MediaSourceHandle && value instanceof G.MediaSourceHandle) {
          // A MediaSource in a worker: the workers this page started hear
          // how big it's shown.
          watchSize(self, sizeHandle);
        }
        return original.set.call(self, value);
      };
    });

    // A play() that failed because the file couldn't play, or because the
    // shim swapped in the converted stream, is tried again once that's
    // ready. One the page paused stays paused.
    hook(proto, 'play', function (original) {
      return function (self, args) {
        var promise = original.apply(self, args);
        if (!promise || typeof promise.then !== 'function') {
          return promise;
        }
        var paused = pauses.get(self) || 0;
        return promise.then(undefined, function (error) {
          var name = error && error.name;
          if (name !== 'NotSupportedError' && name !== 'AbortError') {
            throw error;
          }
          // The job starts with the element's error event, which may come
          // after this.
          return new Promise(function (resolve) {
            task(resolve);
          }).then(function () {
            var job = jobs.get(self);
            if (!job || job.failed || job.done || (pauses.get(self) || 0) !== paused ||
                (name === 'AbortError' && !job.swapped)) {
              throw error;
            }
            return job.ready.then(function (ok) {
              if (!ok || jobs.get(self) !== job || (pauses.get(self) || 0) !== paused) {
                throw error;
              }
              return original.call(self);
            });
          });
        });
      };
    });

    function isCandidate(url) {
      if (typeof url !== 'string' || !/^https?:/i.test(url)) {
        return false;
      }
      var path = url.split(/[?#]/)[0];
      var name = path.slice(path.lastIndexOf('/') + 1);
      var dot = name.lastIndexOf('.');
      return dot < 0 || /^(mp4|m4v|m4a|mov|3gp)$/i.test(name.slice(dot + 1));
    }

    G.addEventListener('error', function (event) {
      var target = event.target;
      if (target instanceof HTMLSourceElement) {
        sourceFailed(target);
        return;
      }
      if (!(target instanceof Media) || broken) {
        return;
      }
      var error = element.error.get.call(target);
      var url = element.currentSrc.get.call(target);
      var job = jobs.get(target);
      if (!error || error.code !== 4 || (job && (job.failed ? job.url === url : !job.done)) ||
          !isCandidate(url)) {
        return;
      }
      // Hidden while the file is converted; it comes back if that fails.
      event.stopImmediatePropagation();
      convertFile(target, url, null);
    }, true);

    // The last <source> failing leaves the element waiting for another
    // rather than in error.
    function sourceFailed(source) {
      var media = source.parentElement;
      var url = source.src;
      var t = source.type ? parse(source.type) : null;
      if (!(media instanceof Media) || jobs.has(media) || !isCandidate(url) || broken ||
          (source.type && !t && !/^(video|audio)\/(mp4|quicktime)\s*$/i.test(source.type))) {
        return;
      }
      var tries = 0;
      (function check() {
        if (jobs.has(media)) {
          return;
        }
        if (media.networkState === 3 && media.readyState === 0) {
          convertFile(media, url, source);
        } else if (media.networkState !== 1 && ++tries < 20) {
          setTimer(check, 100);
        }
      })();
    }

    function installMediaHooks() {
      if (mediaHooked) {
        return;
      }
      mediaHooked = true;
      hookAccessor(proto, 'error', function (original) {
        return function (self) {
          var job = active(self);
          return job && !job.failed && !job.ms ? null : original.get.call(self);
        };
      });
      hookAccessor(proto, 'currentSrc', function (original) {
        return function (self) {
          var job = active(self);
          if (job) {
            return job.url;
          }
          // Left over after the page dropped the source, as the engine's is.
          var value = original.get.call(self);
          var last = blobs.get(self);
          return last && last[0] === value ? last[1] : value;
        };
      });
      hook(G.Element.prototype, 'getAttribute', function (original) {
        return function (self, args) {
          var job = jobs.get(self);
          if (job && job.ms && String(args[0]).toLowerCase() === 'src' && active(self)) {
            return job.attribute;
          }
          return original.apply(self, args);
        };
      });
      hook(proto, 'pause', function (original) {
        return function (self, args) {
          pauses.set(self, (pauses.get(self) || 0) + 1);
          return original.apply(self, args);
        };
      });
      hook(proto, 'load', function (original) {
        return function (self, args) {
          var job = jobs.get(self);
          if (job && job.ms && active(self)) {
            // The MediaSource can't be opened twice: start from the file.
            cancel(job);
            if (job.attribute === null) {
              self.removeAttribute('src');
            } else {
              element.src.set.call(self, job.attribute);
            }
          } else {
            cancel(job);
          }
          return original.apply(self, args);
        };
      });
    }

    // Whether the element still plays what the job converts: the page may
    // change its source in ways the shim doesn't see (setAttribute, a
    // <source>, srcObject).
    function stillOurs(job) {
      var el = job.el;
      if (el.srcObject) {
        return false;
      }
      var attribute = nativeGetAttribute.call(el, 'src');
      if (job.ms) {
        return attribute === job.blob;
      }
      if (attribute !== job.attribute) {
        return false;
      }
      return !job.source || (job.source.parentNode === el && job.source.src === job.url);
    }

    // The element's job, while it's still the element's.
    function active(el) {
      var job = jobs.get(el);
      if (!job) {
        return null;
      }
      if (stillOurs(job)) {
        return job;
      }
      cancel(job);
      jobs.delete(el);
      return null;
    }

    function cancel(job) {
      if (!job || job.done) {
        return;
      }
      job.done = true;
      if (jobs.get(job.el) === job && !job.failed) {
        jobs.delete(job.el);
      }
      // Stops the download and removes the job's listeners.
      job.abort.abort();
      post({ type: 'close', sb: job.id });
      delete conversions[job.id];
      job.out = [];
      job.sb = null;
      job.resolve(false);
    }

    // The conversion didn't work: the page gets the error it would have.
    function giveUp(job) {
      if (job.done) {
        return;
      }
      job.failed = true;
      if (job.ms) {
        var ms = job.ms;
        cancel(job);
        try {
          native.endOfStream.call(ms, 'decode');
        } catch (e) {}
        return;
      }
      cancel(job);
      job.el.dispatchEvent(new NativeEvent('error'));
    }

    // What the converted stream holds, from its init segment.
    function convertedType(init) {
      var text = String.fromCharCode.apply(null, new Uint8Array(init, 0, Math.min(init.byteLength, 4096)));
      var codecs = [];
      if (text.indexOf('vp09') >= 0) {
        codecs.push(VP9);
      }
      if (text.indexOf('fLaC') >= 0) {
        codecs.push(FLAC);
      }
      return codecs.length ? (codecs[0] === VP9 ? 'video' : 'audio') + '/mp4; codecs="' + codecs.join(',') + '"' : null;
    }

    function convertFile(el, url, source) {
      installMediaHooks();
      installSourceBufferHooks();
      anyJob = true;
      var job = {
        el: el, url: url, src: element.src.get.call(el), attribute: nativeGetAttribute.call(el, 'src'),
        source: source, time: el.currentTime, rate: el.playbackRate, abort: new AbortController(),
        id: 0, sent: 0, received: 0, out: [], ms: null, sb: null, blob: null, read: false,
        drained: false, failed: false, done: false, swapped: false, wake: null, mime: null,
        ready: null, resolve: null, size: null,
      };
      job.ready = new Promise(function (resolve) {
        job.resolve = resolve;
      });
      jobs.set(el, job);
      var signal = job.abort.signal;
      job.id = register({
        reply: function (data) {
          if (data.type === 'error') {
            debug('MBGA could not convert ' + url + ': ' + data.message);
            giveUp(job);
            return;
          }
          job.received++;
          job.mime = data.mime || job.mime;
          [data.held, data.bytes].forEach(function (bytes) {
            if (bytes && bytes.byteLength) {
              job.out.push(bytes);
            }
          });
          if (!job.ms && job.out.length) {
            attach(job);
          }
          feed(job);
          wake(job);
        },
        fail: function (message) {
          debug('MBGA could not convert ' + url + ': ' + message);
          giveUp(job);
        },
      });
      // The page loading something else ends the job.
      ['loadstart', 'emptied'].forEach(function (name) {
        el.addEventListener(name, function () {
          if (!stillOurs(job)) {
            cancel(job);
          }
        }, { signal: signal });
      });
      post({ type: 'open', sb: job.id, mime: 'progressive' });
      watchSize(el, function (width, height) {
        if (job.done) {
          return false;
        }
        if (!(job.size && job.size[0] === width && job.size[1] === height) && width > 0 && height > 0) {
          job.size = [width, height];
          post({ type: 'size', sb: job.id, width: width, height: height });
        }
        return true;
      });
      var credentials = el.crossOrigin === 'use-credentials' ? 'include' : 'same-origin';
      fetch(url, { credentials: credentials, signal: signal }).then(function (response) {
        if (!response.ok || !response.body) {
          throw new Error('HTTP ' + response.status);
        }
        var reader = response.body.getReader();
        return (function next() {
          return room(job).then(function () {
            return job.done ? null : reader.read();
          }).then(function (chunk) {
            if (!chunk || job.done) {
              return;
            }
            if (chunk.done) {
              job.read = true;
              feed(job);
              return;
            }
            var bytes = chunk.value.byteOffset || chunk.value.byteLength !== chunk.value.buffer.byteLength
              ? chunk.value.slice().buffer : chunk.value.buffer;
            post({ type: 'append', sb: job.id, seq: ++job.sent, bytes: bytes }, [bytes]);
            return next();
          });
        })();
      }).catch(function () {
        // A site that doesn't allow reading the file (CORS) keeps its error.
        giveUp(job);
      });
    }

    // Waits while plenty is converted ahead of the playhead.
    function room(job) {
      return new Promise(function check(resolve) {
        var buffered = 0;
        var sb = job.sb;
        if (sb && !job.done) {
          var ranges = sb.buffered;
          var now = job.el.currentTime;
          for (var i = 0; i < ranges.length; i++) {
            if (ranges.start(i) <= now + 0.5 && ranges.end(i) > now) {
              buffered = ranges.end(i) - now;
            }
          }
        }
        if (job.done || (job.sent - job.received < 2 && job.out.length < 4 && buffered < LOOKAHEAD)) {
          resolve();
          return;
        }
        job.wake = function () {
          job.wake = null;
          check(resolve);
        };
      });
    }

    function wake(job) {
      if (job.wake) {
        job.wake();
      }
    }

    // Plays the converted stream on the element, which keeps its settings.
    function attach(job) {
      var type = job.mime || convertedType(job.out[0]);
      if (!type) {
        giveUp(job);
        return;
      }
      if (!stillOurs(job)) {
        cancel(job);
        return;
      }
      var el = job.el;
      var signal = job.abort.signal;
      var ms = new MediaSource();
      job.ms = ms;
      job.blob = URL.createObjectURL(ms);
      ms.addEventListener('sourceopen', function () {
        URL.revokeObjectURL(job.blob);
        if (job.done) {
          return;
        }
        try {
          job.sb = native.addSourceBuffer.call(ms, type);
        } catch (e) {
          giveUp(job);
          return;
        }
        job.sb.addEventListener('updateend', function () {
          feed(job);
          wake(job);
        }, { signal: signal });
        feed(job);
      }, { once: true, signal: signal });
      ms.addEventListener('sourceclose', function () {
        cancel(job);
      }, { signal: signal });
      ['timeupdate', 'seeking', 'play'].forEach(function (name) {
        el.addEventListener(name, function () {
          feed(job);
          wake(job);
        }, { signal: signal });
      });
      el.addEventListener('loadedmetadata', function () {
        if (job.time > 0) {
          el.currentTime = job.time;
        }
        if (job.rate !== 1) {
          el.playbackRate = job.rate;
        }
      }, { once: true, signal: signal });
      job.swapped = true;
      blobs.set(el, [job.blob, job.url]);
      element.src.set.call(el, job.blob);
      job.resolve(true);
    }

    // Appends what's converted, and ends the stream after the last of it
    // and of the frames the worker held.
    function feed(job) {
      var sb = job.sb;
      var ms = job.ms;
      if (!sb || job.done || ms.readyState === 'closed' || sb.updating) {
        return;
      }
      if (job.out.length) {
        try {
          native.appendBuffer.call(sb, job.out[0]);
          job.out.shift();
        } catch (e) {
          if (e.name !== 'QuotaExceededError') {
            giveUp(job);
          } else if (job.el.currentTime > 10) {
            // Full: drop what's well behind the playhead, then try again.
            sb.remove(0, job.el.currentTime - 5);
          }
        }
        return;
      }
      if (!job.read || job.received !== job.sent || ms.readyState !== 'open') {
        return;
      }
      if (!job.drained) {
        job.drained = true;
        post({ type: 'drain', sb: job.id, seq: ++job.sent });
        setTimer(function () {
          if (job.received < job.sent) {
            job.received = job.sent;
            feed(job);
          }
        }, 5000);
        return;
      }
      try {
        native.endOfStream.call(ms);
      } catch (e) {}
    }
  }
})();
