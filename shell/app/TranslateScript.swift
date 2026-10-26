enum TranslateScript {
    static let sample = #"""
    (() => {
      const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'CODE', 'PRE', 'SVG', 'MATH']);
      let text = '';
      const body = document.body;
      if (body) {
        const walker = document.createTreeWalker(body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: node => node.nodeType === 3 ? NodeFilter.FILTER_ACCEPT
            : skipped.has(node.tagName.toUpperCase()) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP,
        });
        for (let node = walker.nextNode(); node && text.length < 3000; node = walker.nextNode()) {
          const part = node.nodeValue.trim();
          if (part.length > 1) text += part + ' ';
        }
      }
      return { lang: document.documentElement.lang || '', text, title: document.title || '' };
    })()
    """#

    static let setup = #"""
    (() => {
      if (globalThis.__mbgaTranslate) return true;
      const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'CODE', 'PRE', 'KBD', 'SAMP', 'VAR', 'SVG',
        'MATH', 'TEMPLATE', 'IFRAME', 'CANVAS', 'OBJECT']);
      const names = ['title', 'alt', 'placeholder', 'aria-label'];
      const letter = /\p{L}/u;
      const texts = new WeakMap();
      const attributes = new WeakMap();
      let items = [];
      let pending = [];
      let sorted = false;
      let active = true;
      let waiter = null;
      let timer = 0;
      let titleItem = null;

      const rejects = element => skipped.has(element.tagName.toUpperCase()) || element.translate === false ||
        element.isContentEditable === true || element.classList.contains('notranslate');
      const blocked = node => {
        for (let element = node && node.nodeType === 1 ? node : node && node.parentElement; element;
          element = element.parentElement) {
          if (rejects(element)) return true;
        }
        return false;
      };
      const queue = item => {
        item.state = 0;
        pending.push(item);
        sorted = false;
      };
      const add = (node, get, set) => {
        const original = get();
        if (!original || original.length > 4000 || !letter.test(original)) return null;
        const item = { id: items.length, node, get, set, original, sent: null, shown: null, state: 0, changes: 0 };
        items.push(item);
        queue(item);
        return item;
      };
      const refresh = item => {
        const value = item.get();
        if (value === item.shown || value === item.original) return;
        item.original = value;
        item.shown = null;
        item.changes += 1;
        if (item.state !== 0 && item.changes < 6 && letter.test(value)) queue(item);
      };
      const trackText = node => {
        const known = texts.get(node);
        if (known) return refresh(known);
        const item = add(node, () => node.nodeValue || '', value => { node.nodeValue = value; });
        if (item) texts.set(node, item);
      };
      const trackAttribute = (element, name) => {
        let map = attributes.get(element);
        const known = map && map.get(name);
        if (known) return refresh(known);
        if (!element.hasAttribute(name)) return;
        const item = add(element, () => element.getAttribute(name) || '', value => element.setAttribute(name, value));
        if (!item) return;
        if (!map) {
          map = new Map();
          attributes.set(element, map);
        }
        map.set(name, item);
      };
      const trackAttributes = element => {
        for (const name of names) {
          if (element.hasAttribute(name)) trackAttribute(element, name);
        }
        if (element.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(element.type)) trackAttribute(element, 'value');
      };
      const trackTitle = () => {
        if (titleItem) return refresh(titleItem);
        titleItem = add(null, () => document.title || '', value => { document.title = value; });
      };
      const walk = root => {
        if (root.nodeType === 3) {
          if (letter.test(root.nodeValue)) trackText(root);
          return;
        }
        if (root.nodeType !== 1 || rejects(root)) return;
        trackAttributes(root);
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: node => {
            if (node.nodeType === 3) return letter.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            if (rejects(node)) return NodeFilter.FILTER_REJECT;
            trackAttributes(node);
            return NodeFilter.FILTER_SKIP;
          },
        });
        for (let node = walker.nextNode(); node; node = walker.nextNode()) trackText(node);
      };
      const inTitle = node => {
        const element = node.nodeType === 1 ? node : node.parentElement;
        return !!element && element.closest('title') !== null;
      };
      const wake = () => {
        if (!waiter || !pending.length) return;
        clearTimeout(timer);
        timer = setTimeout(() => {
          const resolve = waiter;
          waiter = null;
          if (resolve) resolve(true);
        }, 300);
      };
      const observer = new MutationObserver(records => {
        if (!active) return;
        const body = document.body;
        for (const record of records) {
          const target = record.target;
          if (inTitle(target)) {
            trackTitle();
          } else if (record.type === 'characterData') {
            const known = texts.get(target);
            if (known) refresh(known);
            else if (body && body.contains(target) && !blocked(target)) walk(target);
          } else if (record.type === 'attributes') {
            const button = target.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(target.type);
            if ((record.attributeName !== 'value' || button) && body && body.contains(target) && !blocked(target)) {
              trackAttribute(target, record.attributeName);
            }
          } else {
            for (const node of record.addedNodes) {
              if (body && body.contains(node) && !blocked(node.parentElement)) walk(node);
            }
          }
        }
        wake();
      });
      const unsort = () => { sorted = false; };
      const rank = item => {
        const element = item.node && (item.node.nodeType === 1 ? item.node : item.node.parentElement);
        if (!element) return 0;
        const rect = element.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) return 3;
        if (rect.bottom > 0 && rect.top < innerHeight) return 0;
        return rect.bottom > -innerHeight && rect.top < innerHeight * 2 ? 1 : 2;
      };

      globalThis.__mbgaTranslate = {
        next(limit, budget) {
          if (!active) return [];
          if (!sorted) {
            const groups = [[], [], [], []];
            for (const item of pending) {
              if (item.state === 0) groups[rank(item)].push(item);
            }
            pending = groups.flat();
            sorted = true;
          }
          const batch = [];
          let size = 0;
          let taken = 0;
          while (taken < pending.length && batch.length < limit && size < budget) {
            const item = pending[taken++];
            if (item.state !== 0) continue;
            const text = item.original.trim().replace(/\s+/g, ' ');
            if (!text) continue;
            item.state = 1;
            item.sent = item.original;
            batch.push([item.id, text]);
            size += text.length;
          }
          pending.splice(0, taken);
          return batch;
        },
        apply(pairs) {
          if (!active) return false;
          for (const [id, text] of pairs) {
            const item = items[id];
            if (!item || item.state !== 1 || item.original !== item.sent || typeof text !== 'string') continue;
            const value = item.original.match(/^\s*/)[0] + text + item.original.match(/\s*$/)[0];
            item.shown = value;
            item.state = 2;
            if (item.get() !== value) item.set(value);
          }
          return true;
        },
        wait(ms) {
          return new Promise(resolve => {
            if (!active) return resolve(false);
            if (pending.length) return resolve(true);
            if (waiter) waiter(true);
            waiter = resolve;
            setTimeout(() => {
              if (waiter !== resolve) return;
              waiter = null;
              resolve(true);
            }, ms);
          });
        },
        restore() {
          active = false;
          observer.disconnect();
          removeEventListener('scroll', unsort, true);
          for (const item of items) {
            if (item.state === 2 && item.get() === item.shown) item.set(item.original);
          }
          items = [];
          pending = [];
          if (waiter) waiter(false);
          waiter = null;
          delete globalThis.__mbgaTranslate;
          return true;
        },
      };
      observer.observe(document.documentElement, {
        childList: true, subtree: true, characterData: true, attributes: true,
        attributeFilter: names.concat(['value']),
      });
      addEventListener('scroll', unsort, { capture: true, passive: true });
      trackTitle();
      if (document.body) walk(document.body);
      return true;
    })()
    """#
}
