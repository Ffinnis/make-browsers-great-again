import Foundation

enum ExtensionShim {
    static func source(token: String, instance: String) -> String {
        script
            .replacingOccurrences(of: "%TOKEN%", with: token)
            .replacingOccurrences(of: "%INSTANCE%", with: instance)
    }

    private static let script = #"""
    (() => {
    if (globalThis.__mbga || typeof chrome !== 'object' || !chrome.runtime || !chrome.runtime.id) return;
    const BRIDGE = 'https://mbga-extension.invalid/%TOKEN%/';
    const INSTANCE = '%INSTANCE%';
    const WINDOW_ID_CURRENT = -2;
    const fetch = globalThis.fetch.bind(globalThis);
    // A worker Chrome starts with the engine can't reach MBGA for its first
    // moments: try again a few times.
    const post = (method, body, tries) => fetch(BRIDGE + method, {method: 'POST', body}).catch(error => {
      if (tries <= 0) { throw error; }
      return new Promise(resolve => setTimeout(resolve, 250)).then(() => post(method, body, tries - 1));
    });
    const call = (method, args) => post(method, JSON.stringify(args === undefined ? {} : args), 12)
      .then(r => r.json())
      .then(reply => {
        if (reply && reply.state) { state = reply.state; }
        if (reply && reply.error) { throw new Error(reply.error); }
        return reply ? reply.value : undefined;
      });

    // MBGA's tabs and windows as of the last answer: {focused, popup,
    // windows, tabs}. In a popup MBGA shows, `popup` is true.
    let state = {focused: false, popup: false, windows: [], tabs: []};
    const fresh = () => call('state').then(() => state);
    const ours = id => state.tabs.find(t => t.id === id);
    const ourWindow = id => state.windows.find(w => w.id === id);

    // Promise-or-callback, as Chrome's own functions are: a callback finds
    // a failure in chrome.runtime.lastError while it runs.
    const withLastError = (message, callback) => {
      let set = false;
      try {
        Object.defineProperty(chrome.runtime, 'lastError', {value: {message}, configurable: true});
        set = true;
      } catch (_) {}
      try { callback(); } finally { if (set) { try { delete chrome.runtime.lastError; } catch (_) {} } }
    };
    const api = fn => function (...args) {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      const result = fn.apply(this, args);
      if (!callback) { return result; }
      result.then(value => callback(value), error => withLastError(String(error && error.message || error), callback));
    };

    const glob = s => new RegExp('^' + s.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$', 'i');
    const pattern = p => {
      if (p === '<all_urls>') { return /^(https?|wss?|file|ftp):/; }
      const m = /^(\*|https?|wss?|file|ftp|chrome-extension):\/\/([^/]*)(\/.*)$/.exec(p);
      if (!m) { return /^$/; }
      const scheme = m[1] === '*' ? '(https?|wss?)' : m[1];
      const host = m[2] === '*' ? '[^/]*' : m[2].startsWith('*.')
        ? '([^/]*\\.)?' + m[2].slice(2).replace(/\./g, '\\.') : m[2].replace(/\./g, '\\.');
      const path = m[3].replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
      return new RegExp('^' + scheme + ':\\/\\/' + host + '(:\\d+)?' + path + '$');
    };
    const matches = (tab, q) => {
      for (const key of ['active', 'pinned', 'audible', 'highlighted', 'discarded', 'autoDiscardable', 'status', 'index', 'groupId', 'frozen']) {
        if (q[key] !== undefined && q[key] !== null && tab[key] !== q[key]) { return false; }
      }
      if (q.muted !== undefined && tab.mutedInfo.muted !== q.muted) { return false; }
      if (q.windowType && q.windowType !== 'normal') { return false; }
      if (q.windowId !== undefined && q.windowId !== WINDOW_ID_CURRENT && q.windowId !== tab.windowId) { return false; }
      if (q.title && !glob(q.title).test(tab.title)) { return false; }
      if (q.url) {
        const urls = Array.isArray(q.url) ? q.url : [q.url];
        if (!urls.some(u => pattern(u).test(tab.url))) { return false; }
      }
      return true;
    };
    // The window "current" means: MBGA's when it was last focused (a popup
    // shown in MBGA is in MBGA's window).
    const mbgaCurrent = () => state.popup || state.focused;
    const focusedWindowOf = () => state.windows.find(w => w.focused) || state.windows[0];

    const tabs = chrome.tabs, windows = chrome.windows;
    const real = {};
    for (const [ns, names] of Object.entries({
      tabs: ['query', 'get', 'getCurrent', 'create', 'update', 'remove', 'duplicate', 'highlight', 'move', 'captureVisibleTab', 'discard'],
      windows: ['get', 'getAll', 'getCurrent', 'getLastFocused', 'create', 'update', 'remove'],
      runtime: ['openOptionsPage'],
    })) {
      if (!chrome[ns]) { continue; }
      real[ns] = {};
      for (const name of names) {
        if (typeof chrome[ns][name] === 'function') { real[ns][name] = chrome[ns][name].bind(chrome[ns]); }
      }
    }
    const define = (object, name, value) => {
      try { Object.defineProperty(object, name, {value, configurable: true, writable: true, enumerable: true}); }
      catch (e) { try { object[name] = value; } catch (_) {} }
    };
    // A tab Chrome described without knowing it's MBGA's, completed.
    const complete = tab => {
      const mine = tab && ours(tab.id);
      return mine ? Object.assign({}, tab, mine) : tab;
    };

    if (tabs) {
      define(tabs, 'query', api(async (q = {}) => {
        await fresh();
        const current = q.currentWindow === true || q.lastFocusedWindow === true ||
          q.windowId === WINDOW_ID_CURRENT;
        const notCurrent = q.currentWindow === false || q.lastFocusedWindow === false;
        const mine = state.tabs.filter(t => matches(t, q) &&
          (!current || t.windowId === (focusedWindowOf() || {}).id));
        if (current && mbgaCurrent()) { return mine; }
        if (q.windowId !== undefined && ourWindow(q.windowId)) { return mine; }
        const theirs = await real.tabs.query(q);
        if (current) { return theirs; }
        return notCurrent && mbgaCurrent() ? theirs : theirs.concat(notCurrent ? [] : mine);
      }));
      define(tabs, 'get', api(async id => {
        await fresh();
        // MBGA's tabs asleep have no browser for Chrome to describe.
        const mine = ours(id);
        if (mine && mine.discarded) { return mine; }
        return complete(await real.tabs.get(id));
      }));
      const reload = tabs.reload && tabs.reload.bind(tabs);
      if (reload) {
        define(tabs, 'reload', api(async (...args) => {
          await fresh();
          const id = typeof args[0] === 'number' ? args[0] : undefined;
          const mine = id === undefined ? null : ours(id);
          if (mine && mine.discarded) { return call('tabs.reload', {id}); }
          return reload(...args);
        }));
      }
      define(tabs, 'getCurrent', api(async () => {
        await fresh();
        if (state.popup) { return undefined; }
        return complete(await real.tabs.getCurrent());
      }));
      define(tabs, 'create', api(async (props = {}) => {
        await fresh();
        if (props.windowId !== undefined && props.windowId !== WINDOW_ID_CURRENT && !ourWindow(props.windowId)) {
          return real.tabs.create(props);
        }
        return call('tabs.create', props);
      }));
      define(tabs, 'update', api(async (...args) => {
        await fresh();
        let [id, props] = args.length > 1 ? args : [undefined, args[0]];
        if (id === undefined) {
          const active = mbgaCurrent() ? state.tabs.find(t => t.active && t.windowId === (focusedWindowOf() || {}).id) : null;
          if (!active) { return real.tabs.update(props); }
          id = active.id;
        }
        if (!ours(id)) { return real.tabs.update(id, props); }
        const {url, active, highlighted, pinned} = props || {};
        if (url && ours(id).discarded) { await call('tabs.update', {id, url}); }
        else if (url) { await real.tabs.update(id, {url}); }
        if (active || highlighted || pinned !== undefined) {
          await call('tabs.update', {id, active: active || highlighted, pinned});
        }
        await fresh();
        return ours(id);
      }));
      define(tabs, 'remove', api(async ids => {
        await fresh();
        const list = Array.isArray(ids) ? ids : [ids];
        const mine = list.filter(id => ours(id)), theirs = list.filter(id => !ours(id));
        if (mine.length) { await call('tabs.remove', {ids: mine}); }
        if (theirs.length) { await real.tabs.remove(theirs); }
      }));
      define(tabs, 'duplicate', api(async id => {
        await fresh();
        const tab = ours(id);
        if (!tab) { return real.tabs.duplicate(id); }
        return call('tabs.create', {url: tab.url, index: tab.index + 1, active: true});
      }));
      define(tabs, 'highlight', api(async info => {
        await fresh();
        const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
        const tab = state.tabs.find(t => t.index === first && (info.windowId === undefined || t.windowId === info.windowId));
        if (!tab) { return real.tabs.highlight(info); }
        await call('tabs.update', {id: tab.id, active: true});
        await fresh();
        return Object.assign({}, ourWindow(tab.windowId), {tabs: state.tabs.filter(t => t.windowId === tab.windowId)});
      }));
      define(tabs, 'move', api(async (ids, props) => {
        await fresh();
        const list = Array.isArray(ids) ? ids : [ids];
        if (!list.some(id => ours(id))) { return real.tabs.move(ids, props); }
        const moved = list.map(id => ours(id)).filter(Boolean);
        return Array.isArray(ids) ? moved : moved[0];
      }));
      define(tabs, 'discard', api(async id => {
        await fresh();
        if (id !== undefined && !ours(id)) { return real.tabs.discard(id); }
        return ours(id);
      }));
      define(tabs, 'captureVisibleTab', api(async (...args) => {
        await fresh();
        const windowId = typeof args[0] === 'number' || args[0] === null || args[0] === undefined
          ? (args.shift() ?? undefined) : undefined;
        const options = args[0] || {};
        if (windowId === undefined || windowId === WINDOW_ID_CURRENT ? !mbgaCurrent() : !ourWindow(windowId)) {
          return real.tabs.captureVisibleTab(windowId, options);
        }
        return call('tabs.capture', options);
      }));
    }

    if (windows) {
      const withTabs = (w, info) => info && info.populate ? Object.assign({}, w, {tabs: state.tabs.filter(t => t.windowId === w.id)}) : Object.assign({}, w);
      define(windows, 'get', api(async (id, info) => {
        await fresh();
        if (id === WINDOW_ID_CURRENT && mbgaCurrent()) { return withTabs(focusedWindowOf(), info); }
        const w = ourWindow(id);
        return w ? withTabs(w, info) : real.windows.get(id, info || {});
      }));
      define(windows, 'getCurrent', api(async info => {
        await fresh();
        if (mbgaCurrent() && state.windows.length) { return withTabs(focusedWindowOf(), info); }
        return real.windows.getCurrent(info || {});
      }));
      define(windows, 'getLastFocused', api(async info => {
        await fresh();
        if (state.focused && state.windows.length) { return withTabs(focusedWindowOf(), info); }
        return real.windows.getLastFocused(info || {});
      }));
      define(windows, 'getAll', api(async info => {
        await fresh();
        const theirs = await real.windows.getAll(info || {});
        if (info && info.windowTypes && !info.windowTypes.includes('normal')) { return theirs; }
        return theirs.concat(state.windows.map(w => withTabs(w, info)));
      }));
      define(windows, 'create', api(async (data = {}) => {
        await fresh();
        if (data.type && data.type !== 'normal') { return real.windows.create(data); }
        const urls = data.url === undefined ? [undefined] : Array.isArray(data.url) ? data.url : [data.url];
        const created = [];
        for (const url of urls) { created.push(await call('tabs.create', {url, active: true})); }
        const w = ourWindow(created[0].windowId) || focusedWindowOf();
        return Object.assign({}, w, {tabs: created});
      }));
      define(windows, 'update', api(async (id, info = {}) => {
        await fresh();
        const w = ourWindow(id);
        if (!w) { return real.windows.update(id, info); }
        if (info.focused || info.drawAttention) { await call('windows.focus', {id}); }
        await fresh();
        return ourWindow(id);
      }));
      define(windows, 'remove', api(async id => {
        await fresh();
        if (!ourWindow(id)) { return real.windows.remove(id); }
      }));
    }

    if (chrome.runtime && real.runtime && real.runtime.openOptionsPage) {
      define(chrome.runtime, 'openOptionsPage', api(() => call('runtime.openOptionsPage')));
    }

    // Events about MBGA's tabs and windows come from MBGA; Chrome's own
    // still arrive for its window. Listeners are counted so MBGA wakes the
    // worker only for events it listens to.
    const own = {};
    // After the script adding listeners finishes (a microtask: timers set
    // while the worker starts never fire). MBGA answers with any events
    // that woke the worker.
    const announce = (() => {
      let pending = false;
      return () => {
        if (pending) { return; }
        pending = true;
        Promise.resolve().then(() => {
          pending = false;
          return call('listeners', {instance: INSTANCE, listeners: Object.keys(own).filter(k => own[k].size)});
        }).then(events => { if (events) { globalThis.__mbga.dispatch(events); } }).catch(() => {});
      };
    })();
    const wrapEvent = (ns, name, adapt) => {
      const target = chrome[ns];
      const event = target && target[name];
      if (!event || typeof event.addListener !== 'function') { return; }
      const key = ns + '.' + name;
      const set = own[key] = new Set();
      const wrapped = new Map();
      const wrapper = {
        addListener(fn, ...rest) {
          if (typeof fn !== 'function' || set.has(fn)) { return; }
          set.add(fn);
          const w = adapt ? adapt(fn) : fn;
          wrapped.set(fn, w);
          event.addListener(w, ...rest);
          announce();
        },
        removeListener(fn) {
          set.delete(fn);
          const w = wrapped.get(fn);
          wrapped.delete(fn);
          if (w) { event.removeListener(w); }
        },
        hasListener: fn => set.has(fn),
        hasListeners: () => set.size > 0,
      };
      define(target, name, wrapper);
    };
    for (const name of ['onActivated', 'onUpdated', 'onCreated', 'onRemoved', 'onHighlighted', 'onMoved', 'onAttached', 'onDetached', 'onReplaced', 'onZoomChange']) {
      wrapEvent('tabs', name);
    }
    for (const name of ['onFocusChanged', 'onCreated', 'onRemoved', 'onBoundsChanged']) { wrapEvent('windows', name); }
    wrapEvent('action', 'onClicked');
    wrapEvent('commands', 'onCommand');
    wrapEvent('contextMenus', 'onClicked');
    // Senders in MBGA's tabs, completed with their window, index and
    // whether they're active.
    const withSender = fn => (message, sender, ...rest) => fn(message, sender && sender.tab ? Object.assign({}, sender, {tab: complete(sender.tab)}) : sender, ...rest);
    const withPort = fn => port => {
      if (port && port.sender && port.sender.tab) {
        try { Object.defineProperty(port, 'sender', {value: Object.assign({}, port.sender, {tab: complete(port.sender.tab)})}); } catch (_) {}
      }
      return fn(port);
    };
    wrapEvent('runtime', 'onMessage', withSender);
    wrapEvent('runtime', 'onMessageExternal', withSender);
    wrapEvent('runtime', 'onConnect', withPort);
    wrapEvent('runtime', 'onConnectExternal', withPort);

    // The toolbar button and menus: Chrome keeps them for its window, MBGA
    // shows them for its own.
    if (chrome.action) {
      const report = (what, details) => call('action', {what, details}).catch(() => {});
      for (const name of ['setBadgeText', 'setBadgeBackgroundColor', 'setBadgeTextColor', 'setTitle', 'setPopup']) {
        const original = chrome.action[name] && chrome.action[name].bind(chrome.action);
        if (!original) { continue; }
        define(chrome.action, name, api(async details => { await original(details); report(name, details); }));
      }
      for (const name of ['enable', 'disable']) {
        const original = chrome.action[name] && chrome.action[name].bind(chrome.action);
        if (!original) { continue; }
        define(chrome.action, name, api(async tabId => { await (tabId === undefined ? original() : original(tabId)); report(name, {tabId}); }));
      }
      const setIcon = chrome.action.setIcon && chrome.action.setIcon.bind(chrome.action);
      if (setIcon) {
        define(chrome.action, 'setIcon', api(async details => {
          await setIcon(details);
          report('setIcon', {tabId: details.tabId, icon: await iconURL(details)});
        }));
      }
      define(chrome.action, 'openPopup', api(options => call('action.openPopup', options || {})));
    }
    const base64 = buffer => {
      let s = '';
      const bytes = new Uint8Array(buffer);
      for (let i = 0; i < bytes.length; i += 0x8000) { s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); }
      return btoa(s);
    };
    const pngOf = async image => {
      const canvas = new OffscreenCanvas(image.width, image.height);
      canvas.getContext('2d').putImageData(image, 0, 0);
      const blob = await canvas.convertToBlob({type: 'image/png'});
      return 'data:image/png;base64,' + base64(await blob.arrayBuffer());
    };
    const largest = v => typeof v === 'object' && v && !('data' in v) && !('width' in v)
      ? v[Object.keys(v).sort((a, b) => b - a)[0]] : v;
    const iconURL = async details => {
      try {
        if (details.imageData) { return await pngOf(largest(details.imageData)); }
        const path = largest(details.path);
        if (!path) { return null; }
        const url = new URL(path, chrome.runtime.getURL('/')).href;
        const response = await fetch(url);
        const type = response.headers.get('content-type') || 'image/png';
        return 'data:' + type + ';base64,' + base64(await response.arrayBuffer());
      } catch (e) { return null; }
    };
    if (chrome.contextMenus) {
      const menus = chrome.contextMenus;
      let reports = Promise.resolve();
      const report = (op, details) => {
        reports = reports.then(() => call('menus', Object.assign({op}, details))).catch(() => {});
      };
      const plain = props => {
        const out = {};
        for (const [k, v] of Object.entries(props || {})) { if (typeof v !== 'function') { out[k] = v; } }
        return out;
      };
      const create = menus.create.bind(menus), update = menus.update.bind(menus);
      const remove = menus.remove.bind(menus), removeAll = menus.removeAll.bind(menus);
      define(menus, 'create', (props, callback) => {
        const id = create(props, callback);
        report('create', {id: props.id !== undefined ? props.id : id, props: plain(props)});
        return id;
      });
      // Told in the order they're called, as Chrome applies them.
      define(menus, 'update', api(async (id, props) => { report('update', {id, props: plain(props)}); await update(id, props); }));
      define(menus, 'remove', api(async id => { report('remove', {id}); await remove(id); }));
      define(menus, 'removeAll', api(async () => { report('removeAll', {}); await removeAll(); }));
    }

    // An extension page in one of MBGA's tabs is the one tab MBGA can't
    // find by its DevTools target: it says which it is.
    if (INSTANCE === 'page' && real.tabs && real.tabs.getCurrent) {
      real.tabs.getCurrent().then(tab => { if (tab) { return call('self', {id: tab.id}); } }).catch(() => {});
    }

    globalThis.__mbga = {
      // Called by MBGA with events for its tabs and windows.
      dispatch(events) {
        for (const [key, args, newState] of events) {
          if (newState) { state = newState; }
          for (const fn of Array.from(own[key] || [])) {
            try { fn(...args); } catch (e) { console.error(e); }
          }
        }
      },
    };
    })();
    """#
}
