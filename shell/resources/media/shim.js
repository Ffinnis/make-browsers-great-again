// Plays H.264 and AAC video, which this engine has no decoders for, by
// converting it in the page. The engine runs this in every frame before the
// page's own scripts (MBEngine.mm, "media shim").
//
// Pages ask whether they can play H.264 (MediaSource.isTypeSupported,
// canPlayType, mediaCapabilities) and hear yes when a conversion would play.
// A SourceBuffer made for H.264 or AAC is a real one made for VP9 and FLAC;
// the bytes the page appends go to a worker (worker.js and mbga_media.wasm,
// from media/) and what comes back is appended instead, with the same
// timing. The page sees the SourceBuffer it expects: its updating flag and
// events follow the page's appends, not the converted ones. A plain MP4 the
// engine refuses (X's GIFs) is fetched, converted the same way and played
// through a MediaSource on the same element.
//
// Players that use MediaSource in a dedicated worker (Twitch's) get it there
// too, without the parts about media elements.
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
  // In a worker the engine adds this binding, which answers with the
  // converter (see startWorker); pages don't need to see it.
  var binding = G.__mbgaCodecLoad;
  if (binding) {
    try {
      delete G.__mbgaCodecLoad;
    } catch (e) {}
  }

  // The page may replace console.debug, which talks to the engine.
  var debug = console.debug.bind(console);
  var SB = G.SourceBuffer.prototype;
  var VP9 = 'vp09.00.41.08';
  var FLAC = 'flac';
  var defineProperty = Object.defineProperty;
  var getDescriptor = Object.getOwnPropertyDescriptor;

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

  function invalidState(what) {
    return new DOMException(
      'Failed to execute \'' + what + '\' on \'SourceBuffer\': This ' +
      'SourceBuffer is still processing an \'appendBuffer\' or \'remove\' ' +
      'operation.', 'InvalidStateError');
  }

  function later(f) {
    Promise.resolve().then(f);
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
    if (broken || typeof G.Worker !== 'function' || typeof G.WebAssembly !== 'object' ||
        typeof G.VideoDecoder !== 'function') {
      return false;
    }
    try {
      var mapped = mapType(type);
      return !!mapped && withinLimits(type) && !nativeSupports(type) && nativeSupports(mapped);
    } catch (e) {
      return false;
    }
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

  // -------------------------------------------------------------- worker

  // One worker per frame, started with the first conversion and shared.
  var worker = null;
  var starting = false;
  var broken = false;
  var outbox = [];
  var nextId = 0;
  // Conversions by id: {output(seq, bytes), error(seq, message)}.
  var conversions = {};

  function post(message, transfer) {
    if (broken) {
      // Appends still get their answer, an error.
      var conversion = message.type === 'append' && conversions[message.sb];
      if (conversion) {
        later(function () {
          conversion.error(message.seq, 'the converter is not available');
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
    // The engine asks every frame of the tab who sent this; this frame
    // answers through who() and gets the worker and the converter. A
    // worker calls its binding instead.
    var ready = function (source, wasm) {
      delete G.__mbgaCodecReady;
      clearTimeout(timeout);
      begin(source, wasm);
    };
    ready.who = debug;
    defineProperty(G, '__mbgaCodecReady', { configurable: true, value: ready });
    var timeout = setTimeout(function () {
      delete G.__mbgaCodecReady;
      fail('the engine did not send the converter');
    }, 15000);
    if (binding) {
      binding('');
    } else {
      debug('__mbga_codec');
    }
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
    if (typeof source !== 'string' || typeof wasm !== 'string') {
      return fail('the converter is missing');
    }
    var url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    var revoke = function () {
      if (url) {
        URL.revokeObjectURL(url);
        url = null;
      }
    };
    try {
      // The page's Content-Security-Policy may forbid blob: workers.
      worker = new Worker(url, { name: 'MBGA video converter' });
    } catch (e) {
      revoke();
      return fail('this site does not allow the converter to start');
    }
    worker.onmessage = function (event) {
      revoke();
      var data = event.data;
      var conversion = data && conversions[data.sb];
      if (!conversion) {
        return;
      }
      if (data.type === 'output') {
        conversion.output(data.seq, data.bytes, data.mime);
      } else if (data.type === 'error') {
        conversion.error(data.seq, String(data.message));
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
  // fails as a decode error would.
  function fail(message) {
    broken = true;
    if (worker) {
      worker.terminate();
      worker = null;
    }
    outbox = [];
    debug('MBGA could not convert video: ' + message);
    Object.keys(conversions).forEach(function (id) {
      var conversion = conversions[id];
      if (conversion) {
        conversion.error(-1, message);
      }
    });
  }

  function register(conversion) {
    var id = ++nextId;
    conversions[id] = conversion;
    if (broken) {
      later(function () {
        conversion.error(-1, 'the converter is not available');
      });
    }
    return id;
  }

  // ------------------------------------------------------- SourceBuffers

  // State of each converted SourceBuffer:
  //   op: the page's append in progress ({seq, out}), out being the
  //       converted bytes once they're back.
  //   internal: the real SourceBuffer is appending converted bytes.
  //   removing: a remove() the page asked for is running, untouched.
  //   carry: converted bytes the real SourceBuffer had no room for; they
  //       go in before the page's next append.
  var states = new WeakMap();
  // Per MediaSource: its converted SourceBuffers and a deferred
  // endOfStream().
  var sources = new WeakMap();
  // The MediaSource of every SourceBuffer made since this frame started.
  var owners = new WeakMap();
  var native = {};
  var EVENTS = ['updatestart', 'update', 'updateend', 'abort', 'error'];

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
  hook(SB, 'changeType', function (original) {
    return function (self, args) {
      var st = states.get(self);
      var type = args[0];
      if (st && st.op) {
        throw invalidState('changeType');
      }
      if (!convertible(type)) {
        original.apply(self, args);
        if (st && st.convert) {
          st.convert = false;
          post({ type: 'close', sb: st.id });
        }
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
      post({ type: 'open', sb: st.id, mime: type });
    };
  });

  function adopt(ms, sb, type) {
    installSourceBufferHooks();
    var st = {
      ms: ms, sb: sb, id: 0, seq: 0, op: null, internal: false,
      removing: false, carry: null, convert: true, dead: false, firing: 0,
    };
    st.id = register({
      output: function (seq, bytes) {
        if (st.op && st.op.seq === seq) {
          st.op.out = bytes || new ArrayBuffer(0);
          pump(st);
        }
      },
      error: function (seq, message) {
        if (st.op && (seq === -1 || st.op.seq === seq)) {
          debug('MBGA could not convert video: ' + message);
          finish(st, true);
          try {
            native.endOfStream.call(st.ms, 'decode');
          } catch (e) {}
        }
      },
    });
    states.set(sb, st);
    var source = sources.get(ms);
    if (!source) {
      source = { list: [], eos: null };
      sources.set(ms, source);
      ms.addEventListener('sourceclose', function () {
        source.list.forEach(close);
        source.list = [];
        source.eos = null;
      });
    }
    source.list.push(st);
    // Ahead of the page's listeners: the real SourceBuffer's events while
    // converted bytes go in are the shim's, and the page gets its own.
    EVENTS.forEach(function (name) {
      sb.addEventListener(name, function (event) {
        guard(st, event);
      }, true);
    });
    post({ type: 'open', sb: st.id, mime: type });
  }

  function close(st) {
    if (st.dead) {
      return;
    }
    st.dead = true;
    st.op = null;
    st.internal = false;
    st.carry = null;
    post({ type: 'close', sb: st.id });
    delete conversions[st.id];
  }

  function fire(st, name) {
    st.firing++;
    try {
      st.sb.dispatchEvent(new Event(name));
    } finally {
      st.firing--;
    }
  }

  function realUpdating(st) {
    return native.updating.get.call(st.sb);
  }

  function guard(st, event) {
    if (st.firing || !st.convert) {
      return;
    }
    if (st.removing) {
      if (event.type === 'updateend') {
        st.removing = false;
      }
      return;
    }
    event.stopImmediatePropagation();
    if (!st.internal || !st.op) {
      return;
    }
    if (event.type === 'error') {
      st.op.failed = true;
    } else if (event.type === 'updateend' && !realUpdating(st)) {
      // An updateend left over from an abort() comes while the real
      // SourceBuffer is busy again; only a real end counts.
      st.internal = false;
      pump(st);
    }
  }

  // Moves the page's append along: converted bytes in, then its end.
  function pump(st) {
    var op = st.op;
    if (!op || st.internal || op.out === null) {
      return;
    }
    if (op.failed) {
      finish(st, true);
      return;
    }
    if (op.out.byteLength && !op.appended) {
      op.appended = true;
      try {
        native.appendBuffer.call(st.sb, op.out);
        st.internal = true;
        return;
      } catch (e) {
        if (e.name !== 'QuotaExceededError') {
          finish(st, true);
          return;
        }
        // The page learns at its next append, as if this one were it,
        // and makes room; these bytes go in first then.
        st.carry = op.out;
      }
    }
    finish(st, false);
  }

  function finish(st, failed) {
    st.op = null;
    st.internal = false;
    if (failed) {
      fire(st, 'error');
    } else {
      fire(st, 'update');
    }
    fire(st, 'updateend');
    var source = sources.get(st.ms);
    if (source && source.eos && !source.list.some(function (s) { return s.op; })) {
      var args = source.eos;
      source.eos = null;
      try {
        native.endOfStream.apply(st.ms, args);
      } catch (e) {}
    }
  }

  function copyBytes(data) {
    if (data instanceof ArrayBuffer) {
      return data.slice(0);
    }
    if (ArrayBuffer.isView(data)) {
      return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice().buffer;
    }
    throw new TypeError('Failed to execute \'appendBuffer\' on \'SourceBuffer\': ' +
                        'The provided value is not of type \'(ArrayBuffer or ArrayBufferView)\'.');
  }

  var hooked = false;
  function installSourceBufferHooks() {
    if (hooked) {
      return;
    }
    hooked = true;
    native.appendBuffer = hook(SB, 'appendBuffer', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert) {
          return original.apply(self, args);
        }
        if (st.op) {
          throw invalidState('appendBuffer');
        }
        if (realUpdating(st) || st.dead) {
          // Removing, or removed: the native call throws the right error.
          return original.call(self, new ArrayBuffer(0));
        }
        var bytes = copyBytes(args[0]);
        if (st.carry) {
          // Throws QuotaExceededError until the page has made room.
          original.call(self, st.carry);
          st.carry = null;
          st.internal = true;
        }
        var op = { seq: ++st.seq, out: null };
        st.op = op;
        later(function () {
          if (st.op === op) {
            fire(st, 'updatestart');
          }
        });
        post({ type: 'append', sb: st.id, seq: op.seq, bytes: bytes }, [bytes]);
      };
    });

    hook(SB, 'abort', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert) {
          return original.apply(self, args);
        }
        var had = st.op;
        original.apply(self, args);
        st.op = null;
        st.internal = false;
        st.carry = null;
        post({ type: 'reset', sb: st.id });
        if (had) {
          later(function () {
            fire(st, 'abort');
            fire(st, 'updateend');
          });
        }
      };
    });

    hook(SB, 'remove', function (original) {
      return function (self, args) {
        var st = states.get(self);
        if (!st || !st.convert) {
          return original.apply(self, args);
        }
        if (st.op) {
          throw invalidState('remove');
        }
        original.apply(self, args);
        st.removing = true;
      };
    });

    native.updating = hookAccessor(SB, 'updating', function (original) {
      return function (self) {
        var st = states.get(self);
        return st && st.convert && st.op ? true : original.get.call(self);
      };
    });

    // Settings that apply to the next append can't change while one runs.
    ['timestampOffset', 'appendWindowStart', 'appendWindowEnd', 'mode'].forEach(function (key) {
      hookAccessor(SB, key, null, function (original) {
        return function (self, value) {
          var st = states.get(self);
          if (st && st.convert && st.op) {
            throw invalidState(key);
          }
          return original.set.call(self, value);
        };
      });
    });

    // endOfStream() while converted bytes are still on their way waits for
    // them, or the stream would end short.
    native.endOfStream = hook(MS.prototype, 'endOfStream', function (original) {
      return function (self, args) {
        var source = sources.get(self);
        if (source && self.readyState === 'open' &&
            source.list.some(function (s) { return s.op; })) {
          source.eos = Array.prototype.slice.call(args);
          return;
        }
        return original.apply(self, args);
      };
    });

    hook(MS.prototype, 'removeSourceBuffer', function (original) {
      return function (self, args) {
        var st = states.get(args[0]);
        var had = st && st.op;
        var result = original.apply(self, args);
        if (st) {
          close(st);
          if (had) {
            fire(st, 'abort');
            fire(st, 'updateend');
          }
        }
        return result;
      };
    });
  }

  // ------------------------------------------------------ plain MP4 files

  if (Media) {
    playPlainFiles();
  }

  function playPlainFiles() {

    // Elements whose MP4 is being converted, with the job doing it.
    var jobs = new WeakMap();
    var mediaHooked = false;
    var element = {};

    // A play() that failed because the file couldn't play is tried again
    // once its conversion is ready.
    hook(Media.prototype, 'play', function (original) {
      return function (self, args) {
        var promise = original.apply(self, args);
        if (!promise || typeof promise.then !== 'function') {
          return promise;
        }
        return promise.then(undefined, function (error) {
          var job = jobs.get(self);
          if (!job || job.failed || !error ||
              (error.name !== 'NotSupportedError' && error.name !== 'AbortError')) {
            throw error;
          }
          return job.ready.then(function (ok) {
            if (!ok) {
              throw error;
            }
            return original.call(self);
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
      if (!(target instanceof Media)) {
        return;
      }
      var error = (element.error ? element.error.get : getDescriptor(Media.prototype, 'error').get).call(target);
      var url = target.currentSrc;
      var job = jobs.get(target);
      if (!error || error.code !== 4 || (job && (job.failed ? job.url === url : true)) ||
          !isCandidate(url) || broken) {
        return;
      }
      // Hidden while the file is converted; it comes back if that fails.
      event.stopImmediatePropagation();
      convertFile(target, url);
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
          convertFile(media, url);
        } else if (media.networkState !== 1 && ++tries < 20) {
          setTimeout(check, 100);
        }
      })();
    }

    function installMediaHooks() {
      if (mediaHooked) {
        return;
      }
      mediaHooked = true;
      var proto = Media.prototype;
      element.error = hookAccessor(proto, 'error', function (original) {
        return function (self) {
          var job = jobs.get(self);
          return job && !job.failed && !job.ms ? null : original.get.call(self);
        };
      });
      element.currentSrc = hookAccessor(proto, 'currentSrc', function (original) {
        return function (self) {
          var job = jobs.get(self);
          return job && !job.failed ? job.url : original.get.call(self);
        };
      });
      element.src = hookAccessor(proto, 'src', function (original) {
        return function (self) {
          var job = jobs.get(self);
          return job && job.ms ? job.src : original.get.call(self);
        };
      }, function (original) {
        return function (self, value) {
          cancel(jobs.get(self));
          return original.set.call(self, value);
        };
      });
      hook(proto, 'load', function (original) {
        return function (self, args) {
          var job = jobs.get(self);
          if (job && job.ms) {
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

    function cancel(job) {
      if (!job || job.done) {
        return;
      }
      job.done = true;
      if (jobs.get(job.el) === job) {
        jobs.delete(job.el);
      }
      job.abort.abort();
      post({ type: 'close', sb: job.id });
      delete conversions[job.id];
      job.resolve(false);
    }

    // The conversion didn't work: the page gets the error it would have.
    function giveUp(job) {
      if (job.done) {
        return;
      }
      if (job.ms) {
        try {
          native.endOfStream.call(job.ms, 'decode');
        } catch (e) {}
        cancel(job);
        return;
      }
      job.failed = true;
      cancel(job);
      jobs.set(job.el, job);
      job.el.dispatchEvent(new Event('error'));
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

    function convertFile(el, url) {
      installMediaHooks();
      installSourceBufferHooks();
      var job = {
        el: el, url: url, src: element.src.get.call(el), attribute: el.getAttribute('src'),
        time: el.currentTime, rate: el.playbackRate, abort: new AbortController(),
        id: 0, sent: 0, received: 0, out: [], ms: null, sb: null, read: false,
        failed: false, done: false, wake: null, mime: null, ready: null, resolve: null,
      };
      job.ready = new Promise(function (resolve) {
        job.resolve = resolve;
      });
      jobs.set(el, job);
      job.id = register({
        output: function (_seq, bytes, mime) {
          job.received++;
          job.mime = mime || job.mime;
          if (bytes && bytes.byteLength) {
            job.out.push(bytes);
          }
          if (!job.ms && job.out.length) {
            attach(job);
          }
          feed(job);
          wake(job);
        },
        error: function (_seq, message) {
          debug('MBGA could not convert ' + url + ': ' + message);
          giveUp(job);
        },
      });
      post({ type: 'open', sb: job.id, mime: 'progressive' });
      var credentials = el.crossOrigin === 'use-credentials' ? 'include' : 'same-origin';
      fetch(url, { credentials: credentials, signal: job.abort.signal }).then(function (response) {
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
        var ahead = 0;
        var sb = job.sb;
        if (sb && !job.done) {
          var ranges = sb.buffered;
          var now = job.el.currentTime;
          for (var i = 0; i < ranges.length; i++) {
            if (ranges.start(i) <= now + 0.5 && ranges.end(i) > now) {
              ahead = ranges.end(i) - now;
            }
          }
        }
        if (job.done || (job.sent - job.received < 4 && job.out.length < 4 && ahead < 30)) {
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
      var el = job.el;
      var ms = new MediaSource();
      job.ms = ms;
      var url = URL.createObjectURL(ms);
      ms.addEventListener('sourceopen', function () {
        URL.revokeObjectURL(url);
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
        });
        feed(job);
      }, { once: true });
      ms.addEventListener('sourceclose', function () {
        cancel(job);
      });
      ['timeupdate', 'seeking', 'play'].forEach(function (name) {
        el.addEventListener(name, function () {
          if (jobs.get(el) === job) {
            feed(job);
            wake(job);
          }
        });
      });
      el.addEventListener('loadedmetadata', function () {
        if (jobs.get(el) !== job) {
          return;
        }
        if (job.time > 0) {
          el.currentTime = job.time;
        }
        if (job.rate !== 1) {
          el.playbackRate = job.rate;
        }
      }, { once: true });
      element.src.set.call(el, url);
      job.resolve(true);
    }

    // Appends what's converted, and ends the stream after the last of it.
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
      if (job.read && job.received === job.sent && ms.readyState === 'open') {
        try {
          native.endOfStream.call(ms);
        } catch (e) {}
      }
    }
  }
})();
