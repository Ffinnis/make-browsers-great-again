(function () {
  'use strict';
  var G = globalThis;
  var Media = G.HTMLMediaElement;
  var Video = G.HTMLVideoElement;
  var MS = G.MediaSource;
  var mark = Symbol.for('mbga.media');
  if (!MS || !G.SourceBuffer || MS[mark]) {
    return;
  }
  Object.defineProperty(MS, mark, { value: true });

  var isWindow = typeof G.Window === 'function' && G instanceof G.Window;
  var debug = console.debug.bind(console);
  var NativeEvent = G.Event;
  var NativeWorker = G.Worker;
  var Handle = G.MediaSourceHandle;
  var Channel = G.MessageChannel;
  var setTimer = function (f, delay) {
    return G.setTimeout(f, delay);
  };
  var clearTimer = function (id) {
    G.clearTimeout(id);
  };
  var now = function () {
    return Date.now();
  };
  var defineProperty = Object.defineProperty;
  var getDescriptor = Object.getOwnPropertyDescriptor;
  var nativeGetAttribute = G.Element ? G.Element.prototype.getAttribute : null;
  var SB = G.SourceBuffer.prototype;
  var VP9 = 'vp09.00.41.08';
  var FLAC = 'flac';
  var LOOKAHEAD = 20;
  var LOOKAHEAD_MAX = 60;
  var LOOKAHEAD_SHORT = 5;
  var DEFER_MAX = 10000;
  var KEEPALIVE = 10000;
  var RETRY = 1000;
  var QUOTA_WAIT = 5000;
  var START_TIMEOUT = 10000;
  var APPEND_TIMEOUT = 60000;
  var CODEC_WAITS = [10000, 20000, 30000];
  var NEAR = '200px';
  var TINY = [320, 180];
  var SMALL = 360;
  var SLOW_FPS = 15;
  var RELAY = '__mbga_media_relay__';

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

  function mapType(type) {
    var t = parse(type);
    if (!t || !t.codecs.some(function (c) { return isAvc(c) || isAac(c); })) {
      return null;
    }
    return t.container + '; codecs="' + t.codecs.map(function (c) {
      return isAvc(c) ? VP9 : isAac(c) ? FLAC : c;
    }).join(',') + '"';
  }

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

  function convertible(type) {
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

  var codec = null;
  var codecDrop = 0;
  var codecWaiters = null;
  var codecTimer = 0;
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
    askCodec(0);
  }

  function askCodec(attempt) {
    codecTimer = setTimer(function () {
      if (attempt + 1 < CODEC_WAITS.length) {
        askCodec(attempt + 1);
      } else {
        gotCodec(null, null);
      }
    }, CODEC_WAITS[attempt]);
    if (isWindow) {
      token = token || Math.random().toString(36).slice(2);
      var answer = function (source, wasm) {
        gotCodec(source, wasm);
      };
      answer.who = function (frame, nonce) {
        debug(frame + ':' + token + ':' + nonce);
      };
      defineProperty(G, '__mbgaCodecReady', { configurable: true, value: answer });
      debug('__mbga_codec');
      return;
    }
    var port = parentPort();
    if (port) {
      port.postMessage({ codec: 'ask' });
    } else {
      gotCodec(null, null);
    }
  }

  function gotCodec(source, wasm) {
    var good = typeof source === 'string' && typeof wasm === 'string';
    if (good) {
      codec = { source: source, wasm: wasm };
      clearTimer(codecDrop);
      codecDrop = setTimer(function () {
        codec = null;
      }, 30000);
    }
    if (!codecWaiters) {
      return;
    }
    clearTimer(codecTimer);
    if (isWindow) {
      delete G.__mbgaCodecReady;
    }
    var waiters = codecWaiters;
    codecWaiters = null;
    waiters.forEach(function (f) {
      f(good ? source : null, good ? wasm : null);
    });
  }

  var parentLink = null;
  function parentPort() {
    if (!parentLink) {
      parentLink = { port: null };
      if (!isWindow && typeof G.postMessage === 'function' && Channel) {
        var channel = new Channel();
        try {
          G.postMessage({ [RELAY]: 1 }, [channel.port2]);
          parentLink.port = channel.port1;
          channel.port1.onmessage = function (event) {
            var data = event.data || {};
            if (data.codec) {
              gotCodec(data.source, data.wasm);
            } else if (data.size) {
              routeSize(data.n, { width: data.width, height: data.height, fps: data.fps || 0 });
            }
          };
        } catch (e) {}
      }
    }
    return parentLink.port;
  }

  var links = new Set();
  var linkOf = new WeakMap();
  var linkIds = 0;
  var linkGone = G.FinalizationRegistry ? new FinalizationRegistry(function (link) {
    unlink(link);
  }) : null;
  var origins = new WeakMap();
  var posted = 0;
  var unposted = 0;
  var slots = new Map();
  var ownSlot = new WeakMap();
  var linkSlot = new Map();
  var msSizes = new WeakMap();
  var anySize = null;
  var msNaturals = new WeakMap();

  function findHandles(data) {
    var found = [];
    var budget = 64;
    (function walk(value, depth) {
      if (!value || typeof value !== 'object' || budget-- <= 0) {
        return;
      }
      if (value instanceof Handle) {
        found.push(value);
        return;
      }
      if (depth > 2) {
        return;
      }
      var values = null;
      try {
        if (Array.isArray(value)) {
          values = value;
        } else if (Object.prototype.toString.call(value) === '[object Object]') {
          values = Object.values(value);
        }
      } catch (e) {}
      for (var i = 0; values && i < values.length && budget > 0; i++) {
        walk(values[i], depth + 1);
      }
    })(data, 0);
    return found;
  }

  function linkFor(worker) {
    var link = linkOf.get(worker);
    if (!link) {
      link = {
        id: ++linkIds, port: null, count: 0, scan: false, sizes: new Map(), views: new Map(),
        naturals: new Map(),
      };
      linkOf.set(worker, link);
      links.add(link);
      if (linkGone) {
        linkGone.register(worker, link);
      }
    }
    return link;
  }

  function childMessage(worker, event) {
    var data = event.data;
    var kind = data && typeof data === 'object' ? data[RELAY] : 0;
    if (kind === 1 && event.ports && event.ports[0]) {
      event.stopImmediatePropagation();
      bind(linkFor(worker), event.ports[0]);
      return;
    }
    if (kind === 2) {
      event.stopImmediatePropagation();
      linkFor(worker).scan = true;
      return;
    }
    var link = Handle && linkOf.get(worker);
    if (link && link.scan) {
      link.scan = false;
      findHandles(data).forEach(function (h) {
        if (!origins.has(h)) {
          unposted++;
        }
        origins.set(h, { link: link, n: link.count++ });
        hookPost();
      });
    }
  }

  function bind(link, port) {
    if (link.port) {
      link.port.close();
    }
    link.port = port;
    port.onmessage = function (event) {
      var data = event.data || {};
      if (data.codec === 'ask') {
        getCodec(function (source, wasm) {
          if (link.port === port) {
            port.postMessage({ codec: 1, source: source, wasm: wasm });
          }
        });
      } else if (data.natural) {
        childNatural(link, data.n, data.clear ? null : { width: data.width, height: data.height }, data.time);
      }
    };
    port.onclose = function () {
      if (link.port === port) {
        unlink(link);
      }
    };
    link.sizes.forEach(function (size, n) {
      sendLink(link, n === 'any' ? undefined : n, size);
    });
  }

  function unlink(link) {
    links.delete(link);
    if (link.port) {
      link.port.onmessage = null;
      link.port.onclose = null;
      link.port.close();
      link.port = null;
    }
    link.sizes.clear();
    link.views.clear();
    link.naturals.clear();
  }

  function sendLink(link, n, size) {
    if (!links.has(link)) {
      return;
    }
    link.sizes.set(n === undefined ? 'any' : n, size);
    if (link.port) {
      link.port.postMessage({ size: 1, n: n, width: size.width, height: size.height, fps: size.fps });
    }
  }

  function routeSize(n, size) {
    if (n === undefined || n === null) {
      anySize = size;
      eachLive(function (st) {
        if (!ownSlot.has(st.ms)) {
          sendSize(st, size);
        }
      });
      links.forEach(function (link) {
        sendLink(link, undefined, size);
      });
      return;
    }
    var slot = slots.get(n);
    var ms = slot && slot.ms && slot.ms.deref();
    if (ms) {
      msSizes.set(ms, size);
      var source = sources.get(ms);
      if (source) {
        source.list.forEach(function (st) {
          sendSize(st, size);
        });
      }
    } else if (slot && slot.link) {
      sendLink(slot.link, slot.n, size);
    }
  }

  function childNatural(link, n, size, time) {
    if (size) {
      link.naturals.set(n, { width: size.width, height: size.height, time: time });
    } else {
      link.naturals.delete(n);
    }
    if (isWindow) {
      var ref = link.views.get(n);
      var el = ref && ref.deref();
      if (el && shown.get(el) && shown.get(el).origin.link === link) {
        addNatural(el, size, time);
      }
      return;
    }
    var own = linkSlot.get(link.id + ':' + n);
    var port = own === undefined ? null : parentPort();
    if (port) {
      port.postMessage(size ? { natural: 1, n: own, width: size.width, height: size.height, time: time }
        : { natural: 1, n: own, clear: 1 });
    }
  }

  var postHooked = false;
  function hookPost() {
    if (postHooked || isWindow || !Handle) {
      return;
    }
    var owner = G;
    while (owner && !Object.prototype.hasOwnProperty.call(owner, 'postMessage')) {
      owner = Object.getPrototypeOf(owner);
    }
    if (!owner) {
      return;
    }
    postHooked = true;
    hook(owner, 'postMessage', function (original) {
      return function (self, args) {
        var toParent = self === G || self === undefined || self === null;
        var found = toParent && unposted > 0 && args[0] && typeof args[0] === 'object' ? findHandles(args[0]) : [];
        if (!found.length) {
          return original.apply(self, args);
        }
        var first = posted;
        posted += found.length;
        try {
          original.call(G, { [RELAY]: 2 });
          var result = original.apply(self, args);
        } catch (e) {
          posted = first;
          throw e;
        }
        unposted = Math.max(0, unposted - found.length);
        found.forEach(function (h, i) {
          numbered(first + i, origins.get(h));
        });
        return result;
      };
    });
  }

  function numbered(n, origin) {
    if (!origin) {
      return;
    }
    slots.set(n, origin);
    var natural;
    var ms = origin.ms && origin.ms.deref();
    if (ms) {
      ownSlot.set(ms, n);
      natural = msNaturals.get(ms);
    } else if (origin.link) {
      linkSlot.set(origin.link.id + ':' + origin.n, n);
      natural = origin.link.naturals.get(origin.n);
    }
    var port = natural ? parentPort() : null;
    if (port) {
      port.postMessage({ natural: 1, n: n, width: natural.width, height: natural.height, time: natural.time });
    }
  }

  if (!isWindow && Handle) {
    hookAccessor(MS.prototype, 'handle', function (original) {
      return function (self) {
        var h = original.get.call(self);
        if (h && !origins.has(h)) {
          origins.set(h, { ms: new WeakRef(self) });
          unposted++;
        }
        hookPost();
        return h;
      };
    });
  }

  if (NativeWorker) {
    hook(NativeWorker.prototype, 'terminate', function (original) {
      return function (self, args) {
        var link = linkOf.get(self);
        if (link) {
          unlink(link);
        }
        return original.apply(self, args);
      };
    });
    defineProperty(G, 'Worker', {
      configurable: true,
      writable: true,
      value: new Proxy(NativeWorker, {
        construct: function (target, args, newTarget) {
          var worker = Reflect.construct(target, args, newTarget);
          worker.addEventListener('message', function (event) {
            childMessage(worker, event);
          });
          return worker;
        },
      }),
    });
  }

  var worker = null;
  var starting = false;
  var broken = false;
  var backoff = 10000;
  var heard = false;
  var silence = 0;
  var outbox = [];
  var nextId = 0;
  var conversions = {};
  var conversionGone = G.FinalizationRegistry ? new FinalizationRegistry(function (id) {
    if (conversions[id]) {
      delete conversions[id];
      live.delete(id);
      post({ type: 'close', sb: id });
    }
  }) : null;

  function post(message, transfer) {
    if (broken) {
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
    if (broken || !starting) {
      return;
    }
    if (typeof source !== 'string' || typeof wasm !== 'string') {
      fail('the engine did not send the converter', false);
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
      worker = new NativeWorker(url, { name: 'MBGA video converter' });
    } catch (e) {
      revoke();
      fail('this site does not allow the converter to start', true);
      return;
    }
    heard = false;
    silence = setTimer(function () {
      fail('the converter did not start', false);
    }, START_TIMEOUT);
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
        fail(String(data.message), true);
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
      fail(event.message || 'the converter stopped', false);
    };
    var bytes = decodeBase64(wasm);
    worker.postMessage({ type: 'wasm', module: bytes.buffer }, [bytes.buffer]);
    var queued = outbox;
    outbox = [];
    queued.forEach(function (item) {
      worker.postMessage(item[0], item[1] || []);
    });
  }

  function fail(message, permanent) {
    if (broken) {
      return;
    }
    broken = true;
    starting = false;
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
    if (!permanent) {
      setTimer(function () {
        broken = false;
      }, backoff);
      backoff = Math.min(backoff * 2, 300000);
    }
  }

  function register(owner, onReply, onFail) {
    var id = ++nextId;
    conversions[id] = conversion(id, new WeakRef(owner), onReply, onFail);
    if (conversionGone) {
      conversionGone.register(owner, id, owner);
    }
    return id;
  }

  function conversion(id, ref, onReply, onFail) {
    return {
      reply: function (data) {
        var it = ref.deref();
        if (it) {
          onReply(it, data, id);
        }
      },
      fail: function (message) {
        var it = ref.deref();
        if (it) {
          onFail(it, message, id);
        }
      },
    };
  }

  function unregister(id, owner) {
    if (conversions[id]) {
      delete conversions[id];
      post({ type: 'close', sb: id });
    }
    if (conversionGone && owner) {
      conversionGone.unregister(owner);
    }
  }

  var msUrls = new WeakMap();
  var urlElements = new Map();
  var sized = new WeakMap();
  var watched = new Set();
  var resizer = null;
  var seer = null;
  var onBattery = false;
  var batteryAsked = false;
  var pageHidden = false;
  var pageAsked = false;
  var shown = new WeakMap();
  var SourceElement = G.HTMLSourceElement;
  var attributesHooked = false;
  var AUTO = { 'auto': 1, 'fit-content': 1, 'min-content': 1, 'max-content': 1 };

  function noteUrl(el, value) {
    if (typeof value === 'string' && value.lastIndexOf('blob:', 0) === 0) {
      urlElements.set(value, new WeakRef(el));
      if (urlElements.size > 32) {
        urlElements.delete(urlElements.keys().next().value);
      }
    }
  }

  if (isWindow && Media) {
    hook(URL, 'createObjectURL', function (original) {
      return function (self, args) {
        var url = original.apply(self, args);
        if (args[0] instanceof MS) {
          msUrls.set(args[0], url);
          hookAttributes();
        }
        return url;
      };
    });
  }

  function hookAttributes() {
    if (attributesHooked || !G.Element) {
      return;
    }
    attributesHooked = true;
    if (SourceElement) {
      hookAccessor(SourceElement.prototype, 'src', null, function (original) {
        return function (self, value) {
          noteUrl(self, value);
          return original.set.call(self, value);
        };
      });
    }
    hook(G.Element.prototype, 'setAttribute', function (original) {
      return function (self, args) {
        var value = args[1];
        if (typeof value === 'string' && value.charCodeAt(0) === 98 &&
            (self instanceof Media || (SourceElement && self instanceof SourceElement)) &&
            String(args[0]).toLowerCase() === 'src') {
          noteUrl(self, value);
        }
        return original.apply(self, args);
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
    if (SourceElement && el instanceof SourceElement) {
      el = el.parentElement;
    }
    if (el instanceof Media) {
      return el;
    }
    var all = document.querySelectorAll('video,audio,video>source,audio>source');
    for (var i = 0; i < all.length; i++) {
      if (nativeGetAttribute.call(all[i], 'src') === url) {
        return all[i] instanceof Media ? all[i] : all[i].parentElement;
      }
    }
    return null;
  }

  function watchSize(el, update) {
    if (!G.ResizeObserver || !el) {
      return function () {};
    }
    var entry = sized.get(el);
    if (!entry) {
      entry = {
        el: el, updates: [], timer: 0, at: 0, css: null, visible: true, pip: null, last: null, pending: null,
        observed: false, events: new AbortController(), back: null,
      };
      sized.set(el, entry);
      watchBattery();
      watchPage();
      var signal = entry.events.signal;
      el.addEventListener('enterpictureinpicture', function (event) {
        var pip = event.pictureInPictureWindow;
        entry.pip = pip || null;
        if (pip) {
          pip.addEventListener('resize', function () {
            if (entry.pip === pip) {
              report(entry);
            }
          }, { signal: signal });
        }
        report(entry);
      }, { signal: signal });
      el.addEventListener('leavepictureinpicture', function () {
        entry.pip = null;
        report(entry);
      }, { signal: signal });
      sweep();
      observe(entry);
    }
    if (entry.updates.indexOf(update) < 0) {
      entry.updates.push(update);
    }
    if (entry.last) {
      update(entry.last);
    }
    return function () {
      unwatch(entry, update);
    };
  }

  function observe(entry) {
    if (entry.observed) {
      return;
    }
    if (!entry.el.isConnected) {
      awaitReturn(entry);
      return;
    }
    entry.observed = true;
    watched.add(entry);
    resizer = resizer || new ResizeObserver(resized);
    resizer.observe(entry.el);
    if (G.IntersectionObserver) {
      seer = seer || new IntersectionObserver(seen, { rootMargin: NEAR });
      seer.observe(entry.el);
    }
  }

  function unobserve(entry) {
    if (!entry.observed) {
      return;
    }
    entry.observed = false;
    watched.delete(entry);
    resizer.unobserve(entry.el);
    if (seer) {
      seer.unobserve(entry.el);
    }
    clearTimer(entry.timer);
    entry.timer = 0;
  }

  function awaitReturn(entry) {
    unobserve(entry);
    if (entry.back) {
      return;
    }
    var back = entry.back = new AbortController();
    var check = function () {
      if (entry.back === back && entry.el.isConnected) {
        back.abort();
        entry.back = null;
        observe(entry);
      }
    };
    ['play', 'playing', 'timeupdate', 'seeking', 'loadeddata'].forEach(function (name) {
      entry.el.addEventListener(name, check, { signal: back.signal });
    });
  }

  function unwatch(entry, update) {
    var i = entry.updates.indexOf(update);
    if (i >= 0) {
      entry.updates.splice(i, 1);
    }
    if (entry.updates.length || sized.get(entry.el) !== entry) {
      return;
    }
    unobserve(entry);
    if (entry.back) {
      entry.back.abort();
      entry.back = null;
    }
    entry.events.abort();
    sized.delete(entry.el);
  }

  function sweep() {
    watched.forEach(function (entry) {
      if (!entry.el.isConnected) {
        awaitReturn(entry);
      }
    });
  }

  function resized(entries) {
    entries.forEach(function (e) {
      var entry = sized.get(e.target);
      if (!entry || !entry.observed) {
        return;
      }
      var css = e.contentBoxSize && e.contentBoxSize[0];
      entry.css = css ? [css.inlineSize, css.blockSize] : [e.contentRect.width, e.contentRect.height];
      report(entry);
    });
    sweep();
  }

  function seen(entries) {
    entries.forEach(function (e) {
      var entry = sized.get(e.target);
      if (entry && entry.observed && entry.visible !== e.isIntersecting) {
        entry.visible = e.isIntersecting;
        report(entry);
      }
    });
    sweep();
  }

  function reportAll() {
    watched.forEach(function (entry) {
      report(entry);
    });
  }

  function watchBattery() {
    if (batteryAsked || !isWindow || !G.navigator || typeof navigator.getBattery !== 'function') {
      return;
    }
    batteryAsked = true;
    try {
      navigator.getBattery().then(function (battery) {
        var update = function () {
          var was = onBattery;
          onBattery = battery.charging === false;
          if (was !== onBattery) {
            reportAll();
          }
        };
        battery.addEventListener('chargingchange', update);
        update();
      }, function () {});
    } catch (e) {}
  }

  function watchPage() {
    if (pageAsked || !isWindow) {
      return;
    }
    pageAsked = true;
    var update = function () {
      var was = pageHidden;
      pageHidden = document.visibilityState === 'hidden';
      if (was !== pageHidden) {
        reportAll();
      }
    };
    document.addEventListener('visibilitychange', update);
    update();
  }

  function autoSized(el) {
    try {
      var map = el.computedStyleMap();
      var width = map.get('width');
      var height = map.get('height');
      return !!width && !!height && AUTO[width.value] === 1 && AUTO[height.value] === 1;
    } catch (e) {
      return false;
    }
  }

  function painted(el, box, video) {
    if (!video) {
      return box;
    }
    var fit = 'contain';
    try {
      fit = String(el.computedStyleMap().get('object-fit'));
    } catch (e) {}
    var contain = Math.min(box[0] / video[0], box[1] / video[1]);
    var cover = Math.max(box[0] / video[0], box[1] / video[1]);
    var scale = fit === 'cover' || fit === 'fill' ? cover : fit === 'none' ? 1
      : fit === 'scale-down' ? Math.min(1, contain) : contain;
    return [video[0] * scale, video[1] * scale];
  }

  function videoSize(el) {
    var nat = naturals.get(el);
    if (nat) {
      return [nat.width, nat.height];
    }
    var real = realSize(el);
    return real[0] > 0 && real[1] > 0 ? real : null;
  }

  function measure(entry) {
    var el = entry.el;
    var css = entry.css;
    if (!css) {
      return null;
    }
    var scale = onBattery ? 1 : G.devicePixelRatio || 1;
    var size;
    var visible;
    if (entry.pip) {
      size = [entry.pip.width * scale, entry.pip.height * scale];
      visible = [entry.pip.width, entry.pip.height];
    } else if (!(css[0] > 0) || !(css[1] > 0)) {
      var last = entry.pending || entry.last;
      return last ? { width: last.width, height: last.height, fps: SLOW_FPS } : null;
    } else if (autoSized(el)) {
      var nat = naturals.get(el);
      if (!nat || !(realSize(el)[0] > 0)) {
        return null;
      }
      size = [nat.width, nat.height];
      visible = css;
    } else {
      var picture = painted(el, css, videoSize(el));
      size = [picture[0] * scale, picture[1] * scale];
      visible = [Math.min(picture[0], css[0]), Math.min(picture[1], css[1])];
    }
    var width = Math.round(size[0]);
    var height = Math.round(size[1]);
    if (!(width > 0) || !(height > 0)) {
      return null;
    }
    var slow = !entry.pip && (!entry.visible || pageHidden || visible[0] < TINY[0] || visible[1] < TINY[1] ||
                              (onBattery && visible[1] < SMALL));
    return { width: width, height: height, fps: slow ? SLOW_FPS : 0 };
  }

  function report(entry) {
    if (!entry.observed) {
      return;
    }
    var size = measure(entry);
    if (!size) {
      return;
    }
    var last = entry.pending || entry.last;
    if (last && last.width === size.width && last.height === size.height && last.fps === size.fps) {
      return;
    }
    var prev = entry.last;
    var grows = !prev || size.width * size.height > prev.width * prev.height || (prev.fps && !size.fps);
    entry.pending = size;
    if (entry.timer) {
      if (!grows) {
        return;
      }
      clearTimer(entry.timer);
      entry.timer = 0;
    }
    if (grows) {
      deliver(entry);
      return;
    }
    entry.timer = setTimer(function () {
      entry.timer = 0;
      deliver(entry);
    }, Math.max(0, 500 - (now() - entry.at)));
  }

  function deliver(entry) {
    var size = entry.pending;
    entry.pending = null;
    if (!size) {
      return;
    }
    entry.last = size;
    entry.at = now();
    entry.updates.slice().forEach(function (f) {
      f(size);
    });
  }

  function capped(el) {
    var entry = el && sized.get(el);
    var size = entry && (entry.pending || entry.last);
    return !!size && size.fps > 0;
  }

  function sendSize(st, size) {
    if (!st.video || st.dead || !st.convert || st.raw || !size || !(size.width > 0) || !(size.height > 0)) {
      return;
    }
    var last = st.size;
    if (last && last.width === size.width && last.height === size.height && last.fps === size.fps) {
      return;
    }
    st.size = size;
    post({ type: 'size', sb: st.id, width: size.width, height: size.height, fps: size.fps || 0 });
  }

  function showHandle(el, handle) {
    unshow(el);
    var origin = origins.get(handle) || null;
    var view = { handle: handle, origin: origin || {}, stop: null };
    shown.set(el, view);
    if (origin && origin.link) {
      origin.link.views.set(origin.n, new WeakRef(el));
      var nat = origin.link.naturals.get(origin.n);
      if (nat) {
        addNatural(el, nat, nat.time);
      }
    }
    view.stop = watchSize(el, function (size) {
      if (origin && origin.link) {
        sendLink(origin.link, origin.n, size);
      } else if (links.size === 1) {
        links.forEach(function (link) {
          sendLink(link, undefined, size);
        });
      }
    });
  }

  function unshow(el) {
    var view = shown.get(el);
    if (view) {
      shown.delete(el);
      view.stop();
    }
  }

  var naturals = new WeakMap();
  var naturalTimes = new WeakMap();
  var resizeSeen = new WeakMap();
  var resizeHandled = new WeakSet();
  var videoProto = Video && Video.prototype;
  var realWidth = videoProto && getDescriptor(videoProto, 'videoWidth');
  var realHeight = videoProto && getDescriptor(videoProto, 'videoHeight');
  var videoHooked = false;

  function realSize(el) {
    if (!realWidth || !(el instanceof Video)) {
      return [0, 0];
    }
    return [realWidth.get.call(el), realHeight.get.call(el)];
  }

  function installVideoHooks() {
    if (videoHooked || !videoProto) {
      return;
    }
    videoHooked = true;
    ['videoWidth', 'videoHeight'].forEach(function (key, i) {
      hookAccessor(videoProto, key, function (original) {
        return function (self) {
          var value = original.get.call(self);
          var nat = value && naturals.get(self);
          return nat ? (i ? nat.height : nat.width) : value;
        };
      });
    });
    hook(videoProto, 'requestVideoFrameCallback', function (original) {
      return function (self, args) {
        var callback = args[0];
        if (typeof callback !== 'function') {
          return original.apply(self, args);
        }
        return original.call(self, function (time, metadata) {
          var nat = naturals.get(self);
          if (nat && metadata) {
            metadata.width = nat.width;
            metadata.height = nat.height;
          }
          return callback.call(this, time, metadata);
        });
      };
    });
    G.addEventListener('resize', onResize, true);
    hookCanvas();
  }

  function onResize(event) {
    var el = event.target;
    if (!(el instanceof Video) || resizeHandled.has(event)) {
      return;
    }
    resizeHandled.add(event);
    if (!naturalTimes.has(el)) {
      return;
    }
    syncNatural(el, true);
    var nat = naturals.get(el);
    if (!nat) {
      return;
    }
    var was = resizeSeen.get(el);
    if (was && was.width === nat.width && was.height === nat.height) {
      event.stopImmediatePropagation();
      return;
    }
    resizeSeen.set(el, nat);
  }

  function onNaturalTime(event) {
    syncNatural(event.target, false);
  }

  function onEmptied(event) {
    clearNatural(event.target);
  }

  function syncNatural(el, quiet) {
    var list = naturalTimes.get(el);
    if (!list || !list.length) {
      return;
    }
    var time = el.currentTime;
    var pick = list[0];
    for (var i = 1; i < list.length && list[i].time <= time + 0.05; i++) {
      pick = list[i];
    }
    var old = naturals.get(el);
    if (old ? old.width === pick.width && old.height === pick.height : !pick.width) {
      return;
    }
    var real = realSize(el);
    if (pick.width) {
      naturals.set(el, { width: pick.width, height: pick.height });
    } else {
      naturals.delete(el);
      resizeSeen.delete(el);
    }
    if (!quiet && real[0] > 0 && (pick.width ? true : real[0] !== old.width || real[1] !== old.height)) {
      task(function () {
        el.dispatchEvent(new NativeEvent('resize'));
      });
    }
    var entry = sized.get(el);
    if (entry) {
      report(entry);
    }
  }

  function addNatural(el, size, time) {
    if (!size) {
      if (typeof time === 'number' && time > 0 && naturals.has(el)) {
        size = { width: 0, height: 0 };
      } else {
        clearNatural(el);
        return;
      }
    }
    if (!videoProto || !(el instanceof Video) || !(size.width >= 0) || !(size.height >= 0)) {
      return;
    }
    installVideoHooks();
    var list = naturalTimes.get(el);
    if (!list) {
      list = [];
      el.addEventListener('resize', onResize, true);
      el.addEventListener('emptied', onEmptied);
      ['timeupdate', 'seeked', 'loadedmetadata'].forEach(function (name) {
        el.addEventListener(name, onNaturalTime);
      });
    }
    var at = typeof time === 'number' && isFinite(time) && naturals.has(el) ? time : -Infinity;
    list = list.filter(function (item) {
      return item.time < at;
    });
    list.push({ time: at, width: size.width, height: size.height });
    naturalTimes.set(el, list.slice(-16));
    syncNatural(el, false);
  }

  function clearNatural(el) {
    if (!el || !naturalTimes.has(el)) {
      return;
    }
    var old = naturals.get(el);
    naturalTimes.delete(el);
    naturals.delete(el);
    resizeSeen.delete(el);
    el.removeEventListener('resize', onResize, true);
    el.removeEventListener('emptied', onEmptied);
    ['timeupdate', 'seeked', 'loadedmetadata'].forEach(function (name) {
      el.removeEventListener(name, onNaturalTime);
    });
    var real = realSize(el);
    if (old && real[0] > 0 && (real[0] !== old.width || real[1] !== old.height)) {
      task(function () {
        el.dispatchEvent(new NativeEvent('resize'));
      });
    }
    var entry = sized.get(el);
    if (entry) {
      report(entry);
    }
  }

  function shrunk(el) {
    var nat = naturals.get(el);
    if (!nat) {
      return null;
    }
    var real = realSize(el);
    if (!(real[0] > 0) || !(real[1] > 0) || (real[0] === nat.width && real[1] === nat.height)) {
      return null;
    }
    return [real[0] / nat.width, real[1] / nat.height, nat];
  }

  function hookCanvas() {
    [G.CanvasRenderingContext2D, G.OffscreenCanvasRenderingContext2D].forEach(function (Context) {
      if (!Context) {
        return;
      }
      hook(Context.prototype, 'drawImage', function (original) {
        return function (self, args) {
          var mapped = args[0] instanceof Video ? drawArgs(args) : null;
          return original.apply(self, mapped || args);
        };
      });
    });
    var owner = G;
    while (owner && !Object.prototype.hasOwnProperty.call(owner, 'createImageBitmap')) {
      owner = Object.getPrototypeOf(owner);
    }
    if (owner) {
      hook(owner, 'createImageBitmap', function (original) {
        return function (self, args) {
          var mapped = args[0] instanceof Video ? bitmapArgs(args) : null;
          return original.apply(self, mapped || args);
        };
      });
    }
  }

  function drawArgs(args) {
    try {
      var f = shrunk(args[0]);
      if (!f) {
        return null;
      }
      var a = Array.prototype.slice.call(args);
      if (a.length === 3) {
        return [a[0], a[1], a[2], f[2].width, f[2].height];
      }
      if (a.length >= 9) {
        a[1] = Number(a[1]) * f[0];
        a[2] = Number(a[2]) * f[1];
        a[3] = Number(a[3]) * f[0];
        a[4] = Number(a[4]) * f[1];
        return a;
      }
    } catch (e) {}
    return null;
  }

  function bitmapArgs(args) {
    try {
      var f = shrunk(args[0]);
      if (!f) {
        return null;
      }
      var a = Array.prototype.slice.call(args);
      var rect = a.length >= 5;
      var at = rect ? 5 : 1;
      var options = Object.assign({}, a[at] && typeof a[at] === 'object' ? a[at] : null);
      if (options.resizeWidth === undefined && options.resizeHeight === undefined) {
        options.resizeWidth = Math.max(1, Math.round(Math.abs(rect ? Number(a[3]) : f[2].width))) || 1;
        options.resizeHeight = Math.max(1, Math.round(Math.abs(rect ? Number(a[4]) : f[2].height))) || 1;
      }
      if (rect) {
        a[1] = Number(a[1]) * f[0];
        a[2] = Number(a[2]) * f[1];
        a[3] = Number(a[3]) * f[0];
        a[4] = Number(a[4]) * f[1];
      }
      a[at] = options;
      return a;
    } catch (e) {
      return null;
    }
  }

  function naturalFor(st, natural, snap) {
    if (!st.video || !natural || !(natural.width > 0) || !(natural.height > 0)) {
      return;
    }
    var size = { width: natural.width, height: natural.height };
    var time = typeof natural.at === 'number' && snap && snap.mode !== 'sequence'
      ? natural.at + snap.timestampOffset : undefined;
    if (isWindow) {
      var source = sources.get(st.ms);
      var el = source && elementFor(source);
      if (el) {
        addNatural(el, size, time);
      }
      return;
    }
    msNaturals.set(st.ms, { width: size.width, height: size.height, time: time });
    var n = ownSlot.get(st.ms);
    var port = n === undefined ? null : parentPort();
    if (port) {
      port.postMessage({ natural: 1, n: n, width: size.width, height: size.height, time: time });
    }
  }

  function naturalGone(st, time) {
    if (!st.video) {
      return;
    }
    var source = sources.get(st.ms);
    if (!source || source.list.some(function (other) {
      return other !== st && other.video && other.convert && !other.dead && !other.raw;
    })) {
      return;
    }
    if (isWindow) {
      if (source.el) {
        addNatural(source.el, null, time);
      }
      return;
    }
    msNaturals.delete(st.ms);
    var n = ownSlot.get(st.ms);
    var port = n === undefined ? null : parentPort();
    if (port) {
      port.postMessage({ natural: 1, n: n, clear: 1, time: time });
    }
  }

  var states = new WeakMap();
  var sources = new WeakMap();
  var owners = new WeakMap();
  var live = new Map();

  function eachLive(f) {
    live.forEach(function (ref) {
      var st = ref.deref();
      if (st) {
        f(st);
      }
    });
  }
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

  native.changeType = hook(SB, 'changeType', function (original) {
    return function (self, args) {
      var st = states.get(self);
      var type = args[0];
      if (!st || !st.convert || st.dead) {
        if (!convertible(type)) {
          return original.apply(self, args);
        }
        original.call(self, mapType(type));
        if (!st) {
          var ms = owners.get(self);
          if (ms) {
            adopt(ms, self, type);
          }
        } else if (!st.dead) {
          resume(st, type);
        }
        return;
      }
      if (updating(st)) {
        throw invalidState('changeType');
      }
      var raw = !convertible(type);
      if (raw) {
        checkType(type);
      }
      reopen(st);
      var change = { change: raw ? String(type) : mapType(type), raw: raw };
      if (st.raw || st.held || st.drain || st.chunks.length || busy(st)) {
        if (st.drain && !st.drain.received) {
          st.drain.changes.push(change);
        } else if (st.held && !st.raw) {
          drainNow(st, change);
        } else {
          st.chunks.push(change);
        }
      } else {
        original.call(self, change.change);
        if (raw) {
          post({ type: 'close', sb: st.id });
          finishRaw(st);
          return;
        }
      }
      if (raw) {
        st.raw = true;
        post({ type: 'close', sb: st.id });
      } else {
        st.raw = false;
        st.video = change.change.indexOf(VP9) >= 0;
        st.size = null;
        post({ type: 'open', sb: st.id, mime: type });
        sizeFor(st);
      }
      pump(st);
    };
  });

  function checkType(type) {
    var text = String(type);
    if (!text) {
      throw new TypeError('Failed to execute \'changeType\' on \'SourceBuffer\': The type provided is empty.');
    }
    if (!nativeSupports(text)) {
      throw new DOMException('Failed to execute \'changeType\' on \'SourceBuffer\': Changing to the type ' +
                             'provided (\'' + text + '\') is not supported.', 'NotSupportedError');
    }
  }

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
      video: mapType(type).indexOf(VP9) >= 0, size: null, sizer: null,
      op: null, drain: null, chunks: [], current: null, reopening: false, unwatch: null,
      removing: false, queuedRemove: null, quota: 0, carry: false, retry: 0, reach: 0,
      page: read(sb), last: null, lastSeq: 0, snaps: new Map(), removals: [], held: false, raw: false,
    };
    st.last = st.page;
    st.id = register(st, reply, failConversion);
    states.set(sb, st);
    live.set(st.id, new WeakRef(st));
    var source = sources.get(ms);
    if (!source) {
      source = { ms: ms, list: [], el: elementOf(ms), eos: null, watching: null, lookahead: LOOKAHEAD };
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
    EVENTS.forEach(function (name) {
      sb.addEventListener(name, function (event) {
        guard(st, event);
      });
    });
    post({ type: 'open', sb: st.id, mime: type });
    sizeFor(st);
  }

  function failConversion(st, message) {
    if (st.convert && !st.raw && !st.dead) {
      failAppend(st, message);
    }
  }

  function resume(st, type) {
    st.convert = true;
    st.raw = false;
    st.video = mapType(type).indexOf(VP9) >= 0;
    st.page = read(st.sb);
    st.last = st.page;
    st.size = null;
    forget(st);
    live.set(st.id, new WeakRef(st));
    post({ type: 'open', sb: st.id, mime: type });
    sizeFor(st);
  }

  function finishRaw(st) {
    st.raw = false;
    st.convert = false;
    dropOutput(st);
    restore(st);
    live.delete(st.id);
    stopSizing(st);
    naturalGone(st, st.reach);
  }

  function elementFor(source) {
    if (!source.el && isWindow) {
      source.el = elementOf(source.ms);
    }
    return source.el;
  }

  function sizeFor(st) {
    if (!st.video) {
      return;
    }
    var source = sources.get(st.ms);
    var el = source && elementFor(source);
    if (el) {
      st.sizer = st.sizer || function (size) {
        sendSize(st, size);
      };
      stopSizing(st);
      st.unwatch = watchSize(el, st.sizer);
      return;
    }
    var size = msSizes.get(st.ms) || (ownSlot.has(st.ms) ? null : anySize);
    if (size) {
      sendSize(st, size);
    }
  }

  function stopSizing(st) {
    if (st.unwatch) {
      st.unwatch();
      st.unwatch = null;
    }
  }

  function close(st) {
    if (st.dead) {
      return;
    }
    naturalGone(st);
    st.dead = true;
    dropOutput(st);
    endOp(st);
    st.queuedRemove = null;
    clearTimer(st.retry);
    live.delete(st.id);
    stopSizing(st);
    unregister(st.id, st);
    var source = sources.get(st.ms);
    if (source) {
      source.list = source.list.filter(function (s) {
        return s !== st;
      });
      endIfDone(source);
    }
  }

  function dropOutput(st) {
    if (st.drain) {
      clearTimer(st.drain.timer);
    }
    st.chunks = [];
    st.current = null;
    st.drain = null;
    st.carry = false;
    st.quota = 0;
    st.held = false;
  }

  function endOp(st) {
    var op = st.op;
    st.op = null;
    if (op) {
      clearTimer(op.timer);
      clearTimer(op.defer);
    }
    return op;
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

  function updating(st) {
    return !!(st.op || st.queuedRemove || st.removing);
  }

  function anyUpdating(ms) {
    var list = ms.sourceBuffers;
    for (var i = 0; i < list.length; i++) {
      var st = states.get(list[i]);
      if (st && st.convert && !st.dead ? updating(st) : native.updating.get.call(list[i])) {
        return true;
      }
    }
    return false;
  }

  function busy(st) {
    return !!(st.current || st.reopening) || realUpdating(st);
  }

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
    if (chunk.snap && chunk.snap.mode === 'sequence') {
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
      if (op && !op.raw && data.seq === op.seq) {
        failAppend(st, String(data.message));
      } else if (drain && data.seq === drain.seq) {
        debug('MBGA could not convert video: ' + data.message);
        drained(st, drain);
      }
      return;
    }
    var mine = op && !op.raw && data.seq === op.seq;
    if (!mine && !(drain && data.seq === drain.seq)) {
      return;
    }
    var snap = mine ? op.snap : st.last;
    if (data.natural) {
      var seq = data.natural.seq;
      naturalFor(st, data.natural, (seq !== undefined && st.snaps.get(seq)) || snap);
    }
    takeHeld(st, data.held);
    if (data.bytes && data.bytes.byteLength) {
      st.chunks.push({ bytes: data.bytes, snap: snap, seq: mine ? op.seq : st.lastSeq, range: data.range || null });
    }
    if (mine) {
      clearTimer(op.timer);
      op.received = true;
      st.last = op.snap;
      st.lastSeq = op.seq;
      st.held = st.video;
    } else {
      clearTimer(drain.timer);
      st.chunks.push.apply(st.chunks, drain.changes);
      drain.received = true;
      st.held = false;
      forget(st);
    }
    pump(st);
  }

  function takeHeld(st, held) {
    if (!held) {
      return;
    }
    var groups = Array.isArray(held) ? held : held.byteLength ? [{ seq: st.lastSeq, bytes: held }] : [];
    groups.forEach(function (group) {
      if (!group || !group.bytes || !group.bytes.byteLength) {
        return;
      }
      var snap = st.snaps.get(group.seq) || st.last;
      if (!removed(st, group, snap)) {
        st.chunks.push({ bytes: group.bytes, snap: snap, seq: group.seq, range: { start: group.start, end: group.end } });
      }
    });
  }

  function removed(st, group, snap) {
    if (!(group.end > group.start)) {
      return false;
    }
    var start = group.start + snap.timestampOffset;
    var end = group.end + snap.timestampOffset;
    return st.removals.some(function (r) {
      return r.seq >= group.seq && r.start < end && start < r.end;
    });
  }

  function removeAgain(st, from, to) {
    var after = -1;
    st.chunks.forEach(function (chunk, i) {
      if (chunk.bytes && overlaps(chunk, from, to)) {
        after = i;
      }
    });
    if (after >= 0) {
      st.chunks.splice(after + 1, 0, { remove: [from, to] });
    }
  }

  function overlaps(chunk, from, to) {
    var range = chunk.range;
    if (!range || !(range.end > range.start) || chunk.snap.mode === 'sequence') {
      return true;
    }
    var offset = chunk.snap.timestampOffset;
    return range.start + offset < to && from < range.end + offset;
  }

  function forget(st) {
    st.snaps.clear();
    st.removals = [];
  }

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
    while (st.chunks.length && (st.chunks[0].change || st.chunks[0].remove)) {
      var next = st.chunks.shift();
      if (next.remove) {
        try {
          native.remove.call(st.sb, next.remove[0], next.remove[1]);
          st.current = next;
          return;
        } catch (e) {
          continue;
        }
      }
      try {
        native.changeType.call(st.sb, next.change);
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
      clearTimer(st.retry);
      st.retry = 0;
      reached(st, chunk);
      return;
    }
    restore(st);
    st.carry = false;
    st.quota = 0;
    if (st.op && st.op.received) {
      complete(st, st.op);
    }
    if (st.drain && st.drain.received) {
      st.drain = null;
    }
    if (st.raw && !st.op && !st.drain && !st.queuedRemove) {
      finishRaw(st);
    }
    endIfDone(sources.get(st.ms));
  }

  function noRoom(st) {
    restore(st);
    var time = now();
    st.quota = st.quota || time;
    var source = sources.get(st.ms);
    var el = source && source.el;
    var playing = !el || (!el.paused && !el.ended);
    var waited = time - st.quota;
    if (st.op && st.op.received && (!playing || waited >= QUOTA_WAIT)) {
      st.carry = true;
      complete(st, st.op);
    }
    if (source && source.eos && waited >= (playing ? 4 : 1) * QUOTA_WAIT) {
      debug('MBGA could not convert video: no room for the end of it');
      st.chunks = st.chunks.filter(function (chunk) {
        return chunk.change || chunk.remove;
      });
      st.carry = false;
      st.quota = 0;
      pump(st);
      return;
    }
    clearTimer(st.retry);
    st.retry = setTimer(function () {
      st.retry = 0;
      pump(st);
    }, playing ? RETRY : 5 * RETRY);
    if (source) {
      watch(source);
    }
  }

  function reached(st, chunk) {
    var range = chunk.range;
    if (range && range.end > range.start && chunk.snap.mode !== 'sequence' && !st.raw) {
      st.reach = Math.max(st.reach, range.end + chunk.snap.timestampOffset);
    }
  }

  function complete(st, op) {
    if (st.op !== op) {
      return;
    }
    endOp(st);
    if (op.snap.mode === 'sequence') {
      st.page.timestampOffset = op.snap.timestampOffset;
    }
    task(function () {
      start(op, st);
      fire(st, 'update');
    });
    task(function () {
      fire(st, 'updateend');
    });
  }

  function start(op, st) {
    if (!op.started) {
      op.started = true;
      fire(st, 'updatestart');
    }
  }

  function failAppend(st, message) {
    debug('MBGA could not convert video: ' + message);
    var op = endOp(st);
    var source = sources.get(st.ms);
    dropOutput(st);
    if (source) {
      source.eos = null;
    }
    if (op) {
      task(function () {
        start(op, st);
        fire(st, 'error');
      });
      task(function () {
        fire(st, 'updateend');
      });
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

  function ahead(el) {
    try {
      var ranges = el.buffered;
      var time = el.currentTime;
      for (var i = 0; i < ranges.length; i++) {
        if (ranges.start(i) <= time + 0.5 && ranges.end(i) > time) {
          return ranges.end(i) - time;
        }
      }
    } catch (e) {}
    return 0;
  }

  function shouldWait(source) {
    var el = source && source.el;
    if (!el || broken || el.paused || el.seeking || el.ended || !el.played.length ||
        !(el.playbackRate > 0) || el.readyState < 3) {
      return false;
    }
    return ahead(el) > (capped(el) ? LOOKAHEAD_SHORT : source.lookahead);
  }

  function dispatch(st) {
    var op = st.op;
    if (!op || op.sent || op.raw || st.dead) {
      return;
    }
    var source = sources.get(st.ms);
    if (!op.forced && shouldWait(source)) {
      if (!op.defer) {
        op.defer = setTimer(function () {
          op.forced = true;
          dispatch(st);
        }, DEFER_MAX);
      }
      watch(source);
      return;
    }
    clearTimer(op.defer);
    op.sent = true;
    var bytes = op.bytes;
    op.bytes = null;
    post({ type: 'append', sb: st.id, seq: op.seq, bytes: bytes }, [bytes]);
    op.timer = setTimer(function () {
      if (st.op === op && !op.received) {
        failAppend(st, 'the converter took too long');
      }
    }, APPEND_TIMEOUT);
  }

  function watch(source) {
    if (source.watching || !source.el) {
      return;
    }
    source.watching = new AbortController();
    var el = source.el;
    var check = function (event) {
      if (event.type === 'waiting' && el.played.length && !el.seeking) {
        source.lookahead = Math.min(LOOKAHEAD_MAX, source.lookahead + 10);
      }
      source.list.forEach(function (st) {
        dispatch(st);
        if (st.chunks.length && !busy(st)) {
          pump(st);
        }
      });
    };
    ['timeupdate', 'seeking', 'play', 'pause', 'ratechange', 'waiting', 'stalled', 'emptied', 'ended']
      .forEach(function (name) {
        el.addEventListener(name, check, { signal: source.watching.signal });
      });
  }

  function reopen(st) {
    reopenSource(sources.get(st.ms));
  }

  function reopenSource(source) {
    if (source && source.eos) {
      source.eos = null;
      task(function () {
        source.ms.dispatchEvent(new NativeEvent('sourceopen'));
      });
    }
  }

  function drainNow(st, change) {
    var drain = { seq: ++st.seq, received: false, changes: change ? [change] : [], timer: 0 };
    st.held = false;
    st.drain = drain;
    post({ type: 'drain', sb: st.id, seq: drain.seq });
    drain.timer = setTimer(function () {
      if (st.drain === drain && !drain.received) {
        drained(st, drain);
      }
    }, 5000);
  }

  function drained(st, drain) {
    clearTimer(drain.timer);
    st.drain = null;
    forget(st);
    st.chunks.push.apply(st.chunks, drain.changes);
    pump(st);
  }

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
    } catch (e) {
      debug('MBGA could not end the stream: ' + e.message);
    }
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
          var result = original.apply(self, args);
          var ms = owners.get(self);
          reopenSource(ms && sources.get(ms));
          return result;
        }
        if (updating(st)) {
          throw invalidState('appendBuffer');
        }
        reopen(st);
        if (readyState(st.ms) === 'ended' && !busy(st)) {
          original.call(self, new ArrayBuffer(0));
          st.reopening = true;
        }
        if (st.carry && st.chunks.length && st.chunks[0].bytes && !busy(st)) {
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
          st.quota = 0;
          reached(st, chunk);
        }
        st.carry = false;
        var op = {
          seq: ++st.seq, snap: Object.assign({}, st.page), bytes: copyBytes(data),
          sent: false, received: false, started: false, raw: st.raw, timer: 0, defer: 0, forced: false,
        };
        st.op = op;
        task(function () {
          start(op, st);
        });
        if (op.raw) {
          op.sent = true;
          op.received = true;
          st.chunks.push({ bytes: op.bytes, snap: op.snap, seq: op.seq, range: null });
          op.bytes = null;
          pump(st);
          return;
        }
        st.snaps.set(op.seq, op.snap);
        if (st.snaps.size > 64) {
          st.snaps.delete(st.snaps.keys().next().value);
        }
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
        var had = st.op;
        var aborted = had ? had.seq : NaN;
        var current = st.current;
        var keepCurrent = !!current && !st.reopening && current.seq !== aborted && readyState(st.ms) === 'open';
        if (!keepCurrent) {
          original.apply(self, args);
        }
        endOp(st);
        var keep = st.chunks.filter(function (chunk) {
          return chunk.change || chunk.remove || chunk.seq !== aborted;
        }).concat(st.drain && !st.drain.received ? st.drain.changes : []);
        var carry = st.carry;
        dropOutput(st);
        forget(st);
        st.reopening = false;
        st.chunks = keep;
        st.current = keepCurrent ? current : null;
        st.carry = carry && keep.some(function (chunk) {
          return chunk.bytes;
        });
        st.page.appendWindowStart = 0;
        st.page.appendWindowEnd = Infinity;
        if (!st.raw) {
          post({ type: 'reset', sb: st.id });
        }
        restore(st);
        if (had) {
          task(function () {
            start(had, st);
            fire(st, 'abort');
          });
          task(function () {
            fire(st, 'updateend');
          });
        }
        pump(st);
      };
    });

    native.remove = hook(SB, 'remove', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert || st.dead) {
          var result = original.apply(self, args);
          var ms = owners.get(self);
          reopenSource(ms && sources.get(ms));
          return result;
        }
        if (updating(st)) {
          throw invalidState('remove');
        }
        var from = Number(args[0]);
        var to = Number(args[1]);
        if (busy(st)) {
          if (!(from >= 0) || !(to > from)) {
            throw new TypeError('Failed to execute \'remove\' on \'SourceBuffer\': ' +
                                'The start provided (' + args[0] + ') is outside the range.');
          }
          reopen(st);
          st.queuedRemove = [from, to];
        } else {
          original.apply(self, args);
          reopen(st);
          st.removing = true;
        }
        removeAgain(st, from, to);
        st.removals.push({ seq: st.seq, start: from, end: to });
        var oldest = st.snaps.size ? st.snaps.keys().next().value : Infinity;
        st.removals = st.removals.filter(function (r) {
          return r.seq >= oldest;
        }).slice(-32);
      };
    });

    native.endOfStream = hook(MS.prototype, 'endOfStream', function (original) {
      return function (self, args) {
        var source = sources.get(self);
        if (!source || !source.list.length) {
          return original.apply(self, args);
        }
        if (source.eos) {
          throw notOpen('endOfStream', 'MediaSource');
        }
        if (readyState(self) !== 'open') {
          return original.apply(self, args);
        }
        if (anyUpdating(self)) {
          throw new DOMException('Failed to execute \'endOfStream\' on \'MediaSource\': The ' +
                                 '\'updating\' attribute is true on one or more of this ' +
                                 'MediaSource\'s SourceBuffers.', 'InvalidStateError');
        }
        var error = args[0];
        if (error !== undefined) {
          if (error !== 'network' && error !== 'decode') {
            return original.apply(self, args);
          }
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
        if (!waiting.length) {
          return original.apply(self, args);
        }
        source.eos = [];
        waiting.forEach(function (st) {
          if (st.held && !st.drain && !st.raw) {
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

  if (Media && isWindow) {
    playPlainFiles();
  }

  function playPlainFiles() {

    var jobs = new WeakMap();
    var anyJob = false;
    var mediaHooked = false;
    var element = {};
    var pauses = new WeakMap();
    var blobs = new WeakMap();
    var proto = Media.prototype;
    element.error = getDescriptor(proto, 'error');
    element.currentSrc = getDescriptor(proto, 'currentSrc');

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
        noteUrl(self, value);
        return original.set.call(self, value);
      };
    });

    hookAccessor(proto, 'srcObject', null, function (original) {
      return function (self, value) {
        if (anyJob) {
          cancel(jobs.get(self));
        }
        if (Handle && value instanceof Handle) {
          showHandle(self, value);
        } else {
          unshow(self);
        }
        return original.set.call(self, value);
      };
    });

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
      event.stopImmediatePropagation();
      convertFile(target, url, null);
    }, true);

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
      job.abort.abort();
      if (job.fetch) {
        job.fetch.abort();
      }
      unregister(job.id, job);
      if (job.unwatch) {
        job.unwatch();
        job.unwatch = null;
      }
      if (job.opened) {
        clearNatural(job.el);
      }
      job.out = [];
      job.sb = null;
      job.resolve(false);
    }

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
        fetch: null, id: 0, sent: 0, received: 0, out: [], ms: null, sb: null, blob: null, read: false,
        drained: false, failed: false, done: false, swapped: false, wake: null, mime: null,
        ready: null, resolve: null, size: null, natural: null, opened: false, reached: 0, windowStart: 0,
        offset: 0, ranges: null, unwatch: null, keepalive: 0,
      };
      job.ready = new Promise(function (resolve) {
        job.resolve = resolve;
      });
      jobs.set(el, job);
      ['loadstart', 'emptied'].forEach(function (name) {
        el.addEventListener(name, function () {
          if (!stillOurs(job)) {
            cancel(job);
          }
        }, { signal: job.abort.signal });
      });
      job.unwatch = watchSize(el, function (size) {
        job.size = size;
        sendJobSize(job);
      });
      startStream(job, 0);
    }

    function sendJobSize(job) {
      var size = job.size;
      if (!job.id || !size || (job.sentSize && job.sentSize.width === size.width &&
          job.sentSize.height === size.height && job.sentSize.fps === size.fps)) {
        return;
      }
      job.sentSize = size;
      post({ type: 'size', sb: job.id, width: size.width, height: size.height, fps: size.fps || 0 });
    }

    function startStream(job, start) {
      if (job.id) {
        unregister(job.id, job);
      }
      job.sent = 0;
      job.received = 0;
      job.out = [];
      job.read = false;
      job.drained = false;
      job.sentSize = null;
      var id = job.id = register(job, streamReply, streamFailed);
      post({ type: 'open', sb: id, mime: 'progressive', start: start });
      sendJobSize(job);
      download(job, id, 0);
    }

    function streamFailed(job, message, id) {
      if (job.id === id) {
        debug('MBGA could not convert ' + job.url + ': ' + message);
        giveUp(job);
      }
    }

    function streamReply(job, data, id) {
      if (job.id !== id || job.done) {
        return;
      }
      if (data.type === 'error') {
        debug('MBGA could not convert ' + job.url + ': ' + data.message);
        giveUp(job);
        return;
      }
      job.received++;
      job.mime = data.mime || job.mime;
      var held = Array.isArray(data.held) ? data.held.map(function (group) {
        return group && group.bytes;
      }) : [data.held];
      held.concat([data.bytes]).forEach(function (bytes) {
        if (bytes && bytes.byteLength) {
          job.out.push(bytes);
        }
      });
      if (data.natural) {
        job.natural = data.natural;
        if (job.opened) {
          addNatural(job.el, data.natural, data.natural.at);
        }
      }
      if (typeof data.need === 'number' && data.need >= 0 && data.need !== job.offset) {
        download(job, id, data.need);
      }
      if (!job.ms && job.out.length) {
        attach(job);
      }
      feed(job);
      wake(job);
    }

    function download(job, id, from) {
      if (job.fetch) {
        job.fetch.abort();
      }
      var fetching = job.fetch = new AbortController();
      job.offset = from;
      job.read = false;
      job.drained = false;
      wake(job);
      var init = {
        credentials: job.el.crossOrigin === 'use-credentials' ? 'include' : 'same-origin',
        signal: fetching.signal,
      };
      if (from > 0 && job.ranges !== false) {
        init.headers = { Range: 'bytes=' + from + '-' };
      }
      fetch(job.url, init).then(function (response) {
        if (!response.ok || !response.body) {
          throw new Error('HTTP ' + response.status);
        }
        var skip = 0;
        if (response.status === 206) {
          var m = /^bytes (\d+)-/.exec(response.headers.get('Content-Range') || '');
          if (m && +m[1] !== from) {
            throw new Error('the server sent another range');
          }
          job.ranges = true;
        } else if (from > 0) {
          job.ranges = false;
          skip = from;
        } else if (/bytes/i.test(response.headers.get('Accept-Ranges') || '')) {
          job.ranges = true;
        }
        var reader = response.body.getReader();
        var ours = function () {
          return !job.done && job.id === id && job.fetch === fetching;
        };
        return (function next() {
          return room(job).then(function () {
            return ours() ? reader.read() : null;
          }).then(function (chunk) {
            if (!chunk || !ours()) {
              return;
            }
            if (chunk.done) {
              job.read = true;
              feed(job);
              return;
            }
            var view = chunk.value;
            if (skip) {
              if (view.byteLength <= skip) {
                skip -= view.byteLength;
                return next();
              }
              view = view.subarray(skip);
              skip = 0;
            }
            var bytes = view.byteOffset || view.byteLength !== view.buffer.byteLength ? view.slice().buffer : view.buffer;
            var offset = job.offset;
            job.offset += bytes.byteLength;
            post({ type: 'append', sb: id, seq: ++job.sent, offset: offset, bytes: bytes }, [bytes]);
            return next();
          });
        })();
      }).catch(function () {
        if (job.id === id && job.fetch === fetching && !fetching.signal.aborted) {
          giveUp(job);
        }
      });
    }

    function room(job) {
      return new Promise(function check(resolve) {
        var buffered = 0;
        var sb = job.sb;
        if (sb && !job.done) {
          var ranges = sb.buffered;
          var time = job.el.currentTime;
          for (var i = 0; i < ranges.length; i++) {
            if (ranges.start(i) <= time + 0.5 && ranges.end(i) > time) {
              buffered = ranges.end(i) - time;
            }
          }
        }
        var lookahead = capped(job.el) ? LOOKAHEAD_SHORT : LOOKAHEAD;
        if (job.done || (job.sent - job.received < 2 && job.out.length < 4 && buffered < lookahead)) {
          resolve();
          return;
        }
        job.wake = function () {
          job.wake = null;
          check(resolve);
        };
        keepAlive(job);
      });
    }

    function keepAlive(job) {
      if (job.keepalive) {
        return;
      }
      var ref = new WeakRef(job);
      var timer = job.keepalive = G.setInterval(function () {
        var it = ref.deref();
        if (!it || it.done || !it.wake || it.keepalive !== timer) {
          G.clearInterval(timer);
          if (it && it.keepalive === timer) {
            it.keepalive = 0;
          }
          return;
        }
        if (!it.el.paused) {
          post({ type: 'keepalive', sb: it.id });
        }
      }, KEEPALIVE);
    }

    function wake(job) {
      if (job.wake) {
        job.wake();
      }
    }

    function seeked(job) {
      var sb = job.sb;
      if (!sb || job.done) {
        return;
      }
      var time = job.el.currentTime;
      var ranges = sb.buffered;
      for (var i = 0; i < ranges.length; i++) {
        if (ranges.start(i) - 0.1 <= time && time < ranges.end(i)) {
          return;
        }
      }
      if (time >= job.reached - 1 && !(job.ranges !== false && time > job.reached + 30)) {
        return;
      }
      job.reached = time;
      startStream(job, time);
    }

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
        job.opened = true;
        if (job.natural) {
          addNatural(el, job.natural, job.natural.at);
        }
        job.sb.addEventListener('updateend', function () {
          var ranges = job.sb ? job.sb.buffered : null;
          if (ranges && ranges.length) {
            job.reached = Math.max(job.reached, ranges.end(ranges.length - 1));
          }
          feed(job);
          wake(job);
        }, { signal: signal });
        feed(job);
      }, { once: true, signal: signal });
      ms.addEventListener('sourceclose', function () {
        cancel(job);
      }, { signal: signal });
      el.addEventListener('seeking', function () {
        seeked(job);
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

    function feed(job) {
      var sb = job.sb;
      var ms = job.ms;
      if (!sb || job.done || ms.readyState === 'closed' || sb.updating) {
        return;
      }
      if (job.out.length) {
        try {
          if (sb.appendWindowStart !== job.windowStart) {
            sb.appendWindowStart = job.windowStart;
          }
          native.appendBuffer.call(sb, job.out[0]);
          job.out.shift();
        } catch (e) {
          if (e.name !== 'QuotaExceededError') {
            giveUp(job);
          } else if (job.el.currentTime > 10) {
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
        var id = job.id;
        post({ type: 'drain', sb: id, seq: ++job.sent });
        setTimer(function () {
          if (job.id === id && job.received < job.sent) {
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
