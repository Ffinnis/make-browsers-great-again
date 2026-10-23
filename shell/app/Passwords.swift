import AppKit
import LocalAuthentication
import Security

enum PasswordSettings {
    static let offersToSaveKey = "offersToSavePasswords"

    static var offersToSave: Bool { UserDefaults.standard.object(forKey: offersToSaveKey) as? Bool ?? true }
}

@MainActor
enum PasswordKey {
    private nonisolated static let service = "MBGA Passwords"
    private static var unlocking: Task<Bool, Never>?

    static func unlock(_ core: BrowserCore) async -> Bool {
        if core.passwordsUnlocked() { return true }
        if let unlocking { return await unlocking.value }
        let task = Task {
            guard let secret = await Task.detached(operation: { secret() }).value else { return false }
            return core.unlockPasswords(secret: secret)
        }
        unlocking = task
        let unlocked = await task.value
        unlocking = nil
        return unlocked
    }

    private nonisolated static func secret() -> Data? {
        if MBEngine.usesMockKeychain {
            let file = dataDirectory.appendingPathComponent("passwords.key")
            if let data = try? Data(contentsOf: file), data.count == 32 { return data }
            guard let data = random() else { return nil }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return data
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "MBGA",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        guard status == errSecItemNotFound, let data = random() else { return nil }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "MBGA",
            kSecAttrLabel: service,
            kSecValueData: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? data : nil
    }

    private nonisolated static func random() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private static var trustedUntil = Date.distantPast

    static func confirmOwner(_ reason: String) async -> Bool {
        if Date() < trustedUntil { return true }
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
            return false
        }
        trustedUntil = Date().addingTimeInterval(60)
        return true
    }
}

@MainActor
final class PasswordFiller {
    private unowned let store: BrowserStore
    private let suggestions = SuggestionPanel()
    private let offer = SaveOfferPanel()

    private struct Field {
        weak var view: MBWebView?
        let tab: UInt64
        let url: String
    }
    private var field: Field?
    private var hideTimer: Timer?

    private struct Sent {
        let url: String
        let username: String
        let password: String
        var navigated = false
    }
    private var sent: [UInt64: Sent] = [:]
    private var usernames: [UInt64: (origin: String, name: String)] = [:]

    init(store: BrowserStore) {
        self.store = store
        suggestions.onChoose = { [weak self] login in self?.fill(login) }
        suggestions.onShowAll = { [weak self] in
            self?.hideSuggestions()
            self?.store.openSettings?(.passwords)
        }
    }

    func receive(_ message: String, url: String, from view: MBWebView) {
        guard let data = message.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? JSON, let type = m.str("t") else { return }
        let tab = view.tabID
        switch type {
        case "focus":
            showSuggestions(m, url: url, in: view)
        case "blur":
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideSuggestions() }
            }
        case "typing":
            hideSuggestions()
        case "key":
            guard field?.tab == tab else { return }
            switch m.str("key") {
            case "ArrowDown": suggestions.move(1)
            case "ArrowUp": suggestions.move(-1)
            case "Enter": suggestions.chooseHighlighted()
            default: hideSuggestions()
            }
        case "user":
            guard let name = m.str("username"), let origin = Self.origin(url) else { return }
            usernames[tab] = (origin, name)
        case "candidate":
            guard PasswordSettings.offersToSave, !store.agentActiveTabs.contains(tab),
                  let password = m.str("password"), !password.isEmpty else { return }
            var username = m.str("username") ?? ""
            if username.isEmpty, let earlier = usernames[tab], earlier.origin == Self.origin(url) { username = earlier.name }
            sent[tab] = Sent(url: url, username: username, password: password)
        case "gone":
            confirm(tab, view: view)
        case "page":
            if m["login"] as? Bool == true { sent[tab] = nil } else { confirm(tab, view: view) }
        default:
            break
        }
    }

    func pageChanged(_ view: MBWebView, url: String) {
        let tab = view.tabID
        if field?.tab == tab { hideSuggestions() }
        if offer.tabID == tab { offer.dismiss() }
        guard var pending = sent[tab], pending.url != url else { return }
        pending.navigated = true
        sent[tab] = pending
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let view, self?.sent[tab]?.navigated == true, self?.store.isLoading(tab) == false else { return }
                view.runScript("window.__mbgaForms && __mbgaForms.check()")
            }
        }
    }

    func pageLoaded(_ view: MBWebView) {
        guard sent[view.tabID]?.navigated == true else { return }
        view.runScript("window.__mbgaForms && __mbgaForms.check()")
    }

    func hide() {
        hideSuggestions()
        offer.dismiss()
    }

    func forget(_ tab: UInt64) {
        sent[tab] = nil
        usernames[tab] = nil
        if field?.tab == tab { hideSuggestions() }
        if offer.tabID == tab { offer.dismiss() }
    }

    private func showSuggestions(_ m: JSON, url: String, in view: MBWebView) {
        hideTimer?.invalidate()
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, window.isKeyWindow,
              !store.agentActiveTabs.contains(view.tabID),
              let profile = store.core.profileOfTab(tabId: view.tabID) else { return hideSuggestions() }
        let logins = store.core.loginsForPage(profileId: profile, url: url)
        guard !logins.isEmpty, let rect = Self.screenRect(m, in: view) else { return hideSuggestions() }
        field = Field(view: view, tab: view.tabID, url: url)
        suggestions.show(logins, page: Self.site(url), under: rect, in: window)
        view.runScript("window.__mbgaForms && __mbgaForms.open(true)")
    }

    private func hideSuggestions() {
        hideTimer?.invalidate()
        guard let field else { return }
        self.field = nil
        suggestions.dismiss()
        field.view?.runScript("window.__mbgaForms && __mbgaForms.open(false)")
    }

    private func fill(_ login: SavedLogin) {
        guard let field, let view = field.view, let origin = Self.origin(field.url) else { return }
        hideSuggestions()
        let core = store.core
        Task {
            guard await PasswordKey.unlock(core), let password = core.loginPassword(id: login.id) else {
                store.showToast(Toast(message: "Couldn't unlock your passwords", symbol: "exclamationmark.triangle"), duration: 2.5)
                return
            }
            let args = [origin, login.username, password].map(FormScript.literal).joined(separator: ",")
            view.runScript("window.__mbgaForms && __mbgaForms.fill(\(args))")
            core.markLoginUsed(id: login.id)
        }
    }

    private func confirm(_ tab: UInt64, view: MBWebView) {
        guard let pending = sent.removeValue(forKey: tab),
              let profile = store.core.profileOfTab(tabId: tab) else { return }
        let core = store.core
        Task {
            guard await PasswordKey.unlock(core) else { return }
            let answer = core.passwordOffer(profileId: profile, url: pending.url, username: pending.username,
                                            password: pending.password)
            let update: Bool
            switch answer {
            case .nothing: return
            case .save: update = false
            case .update: update = true
            }
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
            let site = Self.site(pending.url)
            offer.show(site: site, username: pending.username, update: update, tab: tab, at: view, in: window) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .save:
                    _ = core.saveLogin(profileId: profile, url: pending.url, username: pending.username, password: pending.password)
                    _ = core.persist()
                    store.showToast(Toast(message: update ? "Password updated" : "Password saved", symbol: "key"), duration: 1.6)
                case .never:
                    core.neverSavePasswords(profileId: profile, url: pending.url)
                    _ = core.persist()
                case .notNow:
                    break
                }
            }
        }
    }

    static func origin(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme, let host = parts.host,
              scheme == "https" || scheme == "http" else { return nil }
        return "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }

    static func site(_ url: String) -> String {
        let host = URLComponents(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func screenRect(_ m: JSON, in view: MBWebView) -> NSRect? {
        guard let window = view.window,
              let x = m["x"] as? Double, let y = m["y"] as? Double, let w = m["w"] as? Double, let h = m["h"] as? Double
        else { return nil }
        let k = (m["dpr"] as? Double ?? window.backingScaleFactor) / window.backingScaleFactor
        var rect = NSRect(x: x * k, y: y * k, width: w * k, height: h * k)
        if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
        guard view.bounds.intersects(rect) else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }
}

@MainActor
enum PasswordImport {
    static func available(_ source: ImportSourceInfo) -> Bool {
        source.error == nil && source.kind != .safari && source.profiles.contains { $0.passwords > 0 }
    }

    static func bring(from source: ImportSourceInfo, profileID: String, into profile: UInt64,
                      store: BrowserStore) async -> PasswordImportOutcome {
        let core = store.core
        guard await PasswordKey.unlock(core) else { return .failed("MBGA couldn't unlock its own passwords.") }
        var password: Data?
        switch await SignIns.browserKey(source) {
        case .success(let key): password = key
        case .failure(let error): return .failed(error.message)
        }
        let sourceID = source.id
        return await Task.detached {
            core.importBrowserPasswords(sourceId: sourceID, profileId: profileID, password: password, into: profile)
        }.value
    }

    static func bringFile(into profile: UInt64, store: BrowserStore, window: NSWindow?) async -> PasswordImportOutcome? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose passwords exported from the Passwords app, another browser or a password manager."
        panel.prompt = "Import"
        let response: NSApplication.ModalResponse = if let window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        let core = store.core
        guard await PasswordKey.unlock(core) else { return .failed("MBGA couldn't unlock its own passwords.") }
        let path = url.path
        let result = await Task.detached { core.importPasswordFile(path: path, into: profile) }.value
        _ = core.persist()
        return result
    }

    static func describe(_ r: PasswordImportOutcome, from browser: String, named: Bool = false) -> String {
        if let error = r.error { return "Couldn't bring \(browser)'s passwords: \(error)" }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(r.added.formatted()) password\(r.added == 1 ? "" : "s") added") }
        if r.updated > 0 { parts.append("\(r.updated.formatted()) updated") }
        if r.kept > 0 { parts.append("\(r.kept.formatted()) already saved") }
        if r.unreadable > 0 { parts.append("\(r.unreadable.formatted()) couldn't be read") }
        let text = parts.isEmpty ? "no passwords to bring" : ListFormatter.localizedString(byJoining: parts)
        return named ? "\(browser): \(text)." : text.prefix(1).uppercased() + text.dropFirst() + "."
    }
}

extension PasswordImportOutcome {
    static func failed(_ error: String) -> PasswordImportOutcome {
        PasswordImportOutcome(added: 0, updated: 0, kept: 0, unreadable: 0, error: error)
    }
}

enum FormScript {
    static func literal(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"\""
    }

    static let source = #"""
    (() => {
    if (window.__mbgaForms) return;
    const token = '__MBGA_TOKEN__';
    const send = m => console.debug('__mbga_form:' + token + ':' + JSON.stringify(m));
    const shown = el => el.checkVisibility ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : el.getClientRects().length > 0;
    const usable = el => el instanceof HTMLInputElement && !el.disabled && !el.readOnly;
    const isPassword = el => usable(el) && el.type === 'password';
    const isText = el => usable(el) && ['text', 'email', 'tel'].includes(el.type);
    const ACCOUNT = /user|e-?mail|login|account|identifier|phone|nick/i;
    const named = f => /username|email/.test(f.autocomplete) || ACCOUNT.test([f.name, f.id, f.placeholder, f.getAttribute('aria-label')].join(' '));
    const scope = el => el.form || el.closest('form') || el.getRootNode();
    const passwords = root => [...root.querySelectorAll('input[type=password]')].filter(f => isPassword(f) && shown(f));
    // The field naming the account: the last visible text field before the
    // password, preferring one that says it takes a username or email.
    const userField = (root, password) => {
      const fields = [...root.querySelectorAll('input')].filter(f => isText(f) && shown(f) &&
        (!password || f.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING));
      return fields.filter(named).at(-1) || (password ? fields.at(-1) : null) || null;
    };
    // 'password' or 'username' for the fields of a sign-in form. Fields for
    // a new password (signing up, changing it) get nothing.
    const kind = el => {
      if (isPassword(el)) return el.autocomplete === 'new-password' ? null : 'password';
      if (!isText(el)) return null;
      const root = scope(el);
      const found = passwords(root);
      if (found.length) return userField(root, found[0]) === el ? 'username' : null;
      // The first step of a sign-in, asking for the account alone.
      const step = root instanceof HTMLFormElement && named(el) && root.querySelectorAll('input:not([type=hidden])').length <= 3;
      return /username/.test(el.autocomplete) || step ? 'username' : null;
    };
    let focused = null, open = false, filling = false, sent = '', watching = 0;
    const target = e => e.composedPath()[0];
    const report = el => {
      const k = kind(el);
      if (!k) return false;
      const r = el.getBoundingClientRect();
      send({ t: 'focus', kind: k, x: r.left, y: r.top, w: r.width, h: r.height, dpr: devicePixelRatio });
      return true;
    };
    document.addEventListener('focusin', e => {
      if (filling || target(e) === focused) return;
      focused = report(target(e)) ? target(e) : null;
    }, true);
    document.addEventListener('focusout', e => {
      if (filling || target(e) !== focused) return;
      focused = null;
      send({ t: 'blur' });
    }, true);
    document.addEventListener('mousedown', e => { if (!open && focused && target(e) === focused) report(focused); }, true);
    document.addEventListener('input', e => { if (open && !filling && target(e) === focused) send({ t: 'typing' }); }, true);
    addEventListener('scroll', () => { if (open) send({ t: 'typing' }); }, { capture: true, passive: true });
    document.addEventListener('keydown', e => {
      if (!focused || target(e) !== focused) return;
      if (!open) {
        if (e.key === 'ArrowDown') report(focused);
        else if (e.key === 'Enter') candidate(scope(focused));
        return;
      }
      if (e.key === 'Tab') return send({ t: 'typing' });
      if (!['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      send({ t: 'key', key: e.key });
    }, true);
    // A sign-in that works without leaving the page takes its form away.
    const watch = field => {
      clearInterval(watching);
      let ticks = 0;
      watching = setInterval(() => {
        if (!field.isConnected || !shown(field)) { clearInterval(watching); sent = ''; send({ t: 'gone' }); }
        else if (++ticks > 20) clearInterval(watching);
      }, 500);
    };
    // A password on its way: the new one when signing up or changing it.
    const candidate = root => {
      const filled = passwords(root).filter(f => f.value);
      if (!filled.length) {
        const user = root instanceof HTMLFormElement ? userField(root, null) : null;
        if (user && user.value.trim()) send({ t: 'user', username: user.value.trim() });
        return;
      }
      const fresh = filled.find(f => f.autocomplete === 'new-password');
      const password = fresh || (filled.length === 1 ? filled[0]
        : filled.length === 2 && filled[0].value === filled[1].value ? filled[0] : filled[1]);
      const user = userField(root, filled[0]);
      const m = { t: 'candidate', username: user ? user.value.trim() : '', password: password.value };
      if (m.username + '\n' + m.password !== sent) {
        sent = m.username + '\n' + m.password;
        send(m);
      }
      watch(password);
    };
    document.addEventListener('submit', e => candidate(e.target), true);
    document.addEventListener('click', e => {
      const button = target(e).closest && target(e).closest('button, input[type=submit], input[type=image], [role=button]');
      if (button) candidate(scope(button));
    }, true);
    const set = (el, value) => {
      el.focus();
      // Through the prototype's setter, so frameworks tracking the value
      // see the change.
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const fill = (origin, username, password) => {
      open = false;
      if (location.origin !== origin) return;
      const el = focused && focused.isConnected ? focused : document.activeElement;
      const root = el && el !== document.body ? scope(el) : document;
      const field = passwords(root).find(f => f.autocomplete !== 'new-password');
      const user = field ? userField(root, field) : isText(el) ? el : null;
      filling = true;
      try {
        if (user && username) set(user, username);
        if (field) set(field, password);
        if (el && el.isConnected) el.focus();
      } finally {
        filling = false;
      }
    };
    const check = () => send({ t: 'page', login: passwords(document).length > 0 });
    Object.defineProperty(window, '__mbgaForms', { value: Object.freeze({ fill, check, open: v => { open = v; } }) });
    })();
    """#
}
