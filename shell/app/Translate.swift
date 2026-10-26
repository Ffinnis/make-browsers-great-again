import AppKit

enum TranslationPhase: Equatable {
    case offered, translating, translated, proxied
}

struct TranslationState: Equatable {
    let tabID: UInt64
    let phase: TranslationPhase
    let language: PageLanguage?
}

@MainActor
final class PageTranslator {
    static let translateItem = "mbga.translate"
    static let originalItem = "mbga.translate.original"

    private unowned let store: BrowserStore
    private var languages: [UInt64: PageLanguage] = [:]
    private var phases: [UInt64: TranslationPhase] = [:]
    private var jobs: [UInt64: TranslationJob] = [:]
    private var originals: [UInt64: String] = [:]
    private var following: [UInt64: String] = [:]
    private var declined: Set<String> = []
    private lazy var bar = TranslateBarView(translator: self, container: store.webContainer)

    private static let all = NSMapTable<BrowserStore, PageTranslator>.weakToStrongObjects()

    static func of(_ store: BrowserStore) -> PageTranslator {
        if let translator = all.object(forKey: store) { return translator }
        let translator = PageTranslator(store: store)
        all.setObject(translator, forKey: store)
        return translator
    }

    private init(store: BrowserStore) {
        self.store = store
        store.observe(self) { [weak self] _ in self?.storeChanged() }
    }

    var visibleState: TranslationState? {
        guard let id = store.visibleTabID, let phase = phases[id] else { return nil }
        return TranslationState(tabID: id, phase: phase, language: languages[id])
    }

    var canTranslate: Bool {
        guard let id = store.visibleTabID, store.views[id] != nil, Self.isWeb(url(of: id)) else { return false }
        return phases[id] == nil || phases[id] == .offered
    }

    var canShowOriginal: Bool {
        guard let id = store.visibleTabID else { return false }
        return phases[id] == .translating || phases[id] == .translated || phases[id] == .proxied
    }

    func translateVisible() {
        guard let id = store.visibleTabID, let view = store.views[id] else { return }
        translate(view)
    }

    func showOriginalVisible() {
        guard let id = store.visibleTabID else { return }
        showOriginal(id)
    }

    func dismissOffer() {
        guard let state = visibleState else { return }
        bar.hide()
        guard state.phase == .offered else { return }
        if let code = state.language?.code { declined.insert(code) }
        phases[state.tabID] = nil
    }

    func pageLoaded(_ view: MBWebView) {
        let id = view.tabID
        jobs.removeValue(forKey: id)?.cancel(restoring: false)
        languages[id] = nil
        let url = url(of: id)
        if Self.isProxied(url) {
            set(.proxied, for: id)
            return
        }
        originals[id] = nil
        set(nil, for: id)
        guard Self.isWeb(url) else { return }
        Task { await detect(view, url: url, retry: true) }
    }

    func menuItems(for context: [String: Any]) -> [[String: Any]] {
        guard (context["contexts"] as? [String])?.contains("page") == true else { return [] }
        if canShowOriginal { return [["id": Self.originalItem, "title": "Show Original"]] }
        guard canTranslate else { return [] }
        return [["id": Self.translateItem, "title": "Translate to \(PageLanguage.targetName)"]]
    }

    func choose(_ item: String, in view: MBWebView) -> Bool {
        switch item {
        case Self.translateItem: translate(view)
        case Self.originalItem: showOriginal(view.tabID)
        default: return false
        }
        return true
    }

    private func translate(_ view: MBWebView) {
        let id = view.tabID
        guard jobs[id] == nil, phases[id] != .proxied, Self.isWeb(url(of: id)) else { return }
        if let language = languages[id] {
            start(view, language)
            return
        }
        Task {
            let url = url(of: id)
            guard let language = await language(of: view), url == self.url(of: id) else {
                proxy(view)
                return
            }
            languages[id] = language
            start(view, language)
        }
    }

    private func start(_ view: MBWebView, _ language: PageLanguage) {
        let id = view.tabID
        if language.isPreferred {
            store.showToast(Toast(message: "This page is already in \(language.name)", symbol: "translate"))
            return
        }
        guard let translator = language.deviceTranslator() else {
            proxy(view)
            return
        }
        let job = TranslationJob(view: view, translate: translator) { [weak self, weak view] event in
            guard let self, let view else { return }
            finished(event, view: view, language: language)
        }
        jobs[id] = job
        following[id] = language.code
        set(.translating, for: id)
        job.start()
    }

    private func finished(_ event: TranslationJob.Event, view: MBWebView, language: PageLanguage) {
        let id = view.tabID
        guard jobs[id] != nil else { return }
        switch event {
        case .translated:
            set(.translated, for: id)
        case .ended:
            jobs[id] = nil
            if phases[id] == .translating { set(nil, for: id) }
        case .failed:
            jobs[id] = nil
            var fallback = language
            fallback.onDevice = false
            languages[id] = fallback
            following[id] = nil
            set(nil, for: id)
            proxy(view)
        }
    }

    private func proxy(_ view: MBWebView) {
        let id = view.tabID
        let url = url(of: id)
        guard Self.isWeb(url), var parts = URLComponents(string: "https://translate.google.com/translate") else { return }
        parts.queryItems = [
            URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "tl", value: PageLanguage.googleTarget),
            URLQueryItem(name: "u", value: url),
        ]
        guard let target = parts.url?.absoluteString else { return }
        originals[id] = url
        following[id] = nil
        set(.proxied, for: id)
        view.loadURL(target)
    }

    private func showOriginal(_ id: UInt64) {
        guard let view = store.views[id] else { return }
        following[id] = nil
        if phases[id] == .proxied {
            let original = originals.removeValue(forKey: id) ?? Self.unproxied(url(of: id))
            set(nil, for: id)
            if let original { view.loadURL(original) }
            return
        }
        jobs.removeValue(forKey: id)?.cancel(restoring: true)
        set(nil, for: id)
    }

    private func detect(_ view: MBWebView, url: String, retry: Bool) async {
        let id = view.tabID
        let found = await language(of: view)
        guard store.views[id] === view, url == self.url(of: id), jobs[id] == nil, phases[id] == nil else { return }
        guard let found else {
            guard retry else { return }
            try? await Task.sleep(for: .seconds(2))
            await detect(view, url: url, retry: false)
            return
        }
        languages[id] = found
        if found.isPreferred { return }
        if following.removeValue(forKey: id) == found.code, found.onDevice {
            start(view, found)
        } else if !declined.contains(found.code) {
            set(.offered, for: id)
        }
    }

    private func language(of view: MBWebView) async -> PageLanguage? {
        guard let page = try? await PageScripts.evaluate(view, TranslateScript.sample) as? [String: Any] else { return nil }
        let sample = "\(page["title"] as? String ?? "") \(page["text"] as? String ?? "")"
        guard let language = PageLanguage.detect(declared: page["lang"] as? String ?? "", sample: sample) else { return nil }
        return await language.checkingDevice()
    }

    private func set(_ phase: TranslationPhase?, for id: UInt64) {
        guard phases[id] != phase else { return }
        phases[id] = phase
        guard id == store.visibleTabID else { return }
        showBar()
    }

    private func showBar() {
        guard let state = visibleState, let card = store.webContainer.superview else {
            bar.hide()
            return
        }
        if bar.superview !== card { card.addSubview(bar) }
        bar.show(state)
    }

    private func storeChanged() {
        if let shown = bar.state, shown.tabID != store.visibleTabID { bar.hide() }
        let live = Set(store.views.keys)
        for id in Set(phases.keys).union(languages.keys).union(jobs.keys) where !live.contains(id) {
            phases[id] = nil
            languages[id] = nil
            jobs.removeValue(forKey: id)?.cancel(restoring: false)
            originals[id] = nil
            following[id] = nil
        }
    }

    private func url(of id: UInt64) -> String {
        store.core.tab(id: id)?.url ?? ""
    }

    private static func isWeb(_ url: String) -> Bool {
        url.hasPrefix("https://") || url.hasPrefix("http://")
    }

    private static func isProxied(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url), let host = parts.host else { return false }
        return host.hasSuffix(".translate.goog") || host == "translate.google.com" && parts.path == "/translate"
    }

    static func unproxied(_ url: String) -> String? {
        guard var parts = URLComponents(string: url), let host = parts.host else { return nil }
        if host == "translate.google.com" { return parts.queryItems?.first { $0.name == "u" }?.value }
        guard host.hasSuffix(".translate.goog") else { return nil }
        let encoded = String(host.dropLast(".translate.goog".count))
        let marker = "\u{1}"
        parts.host = encoded.replacingOccurrences(of: "--", with: marker).replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: marker, with: "-")
        parts.queryItems = parts.queryItems?.filter { !$0.name.hasPrefix("_x_tr_") }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.url?.absoluteString
    }
}

extension BrowserStore {
    var translator: PageTranslator { PageTranslator.of(self) }

    func pageLoaded(_ view: MBWebView) {
        passwords.pageLoaded(view)
        translator.pageLoaded(view)
    }

    func pageMenuItems(profile: UInt64, context: [String: Any]) -> [[String: Any]] {
        translator.menuItems(for: context) + extensions.pageMenuItems(profile: extensions.profilePath(profile), context: context)
    }
}

@MainActor
final class TranslateMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = TranslateMenuTarget()

    private var translator: PageTranslator? { (NSApp.delegate as? AppDelegate)?.store.translator }

    @objc func translatePage(_ sender: Any?) { translator?.translateVisible() }
    @objc func showOriginalPage(_ sender: Any?) { translator?.showOriginalVisible() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(translatePage(_:)): translator?.canTranslate == true
        case #selector(showOriginalPage(_:)): translator?.canShowOriginal == true
        default: true
        }
    }
}

@MainActor
extension NSMenu {
    func addingTranslateItems() -> NSMenu {
        guard let view = items.first(where: { $0.title == "View" })?.submenu,
              let zoom = view.items.firstIndex(where: { $0.title == "Actual Size" }) else { return self }
        let entries: [(String, Selector)] = [
            ("Translate Page", #selector(TranslateMenuTarget.translatePage(_:))),
            ("Show Original", #selector(TranslateMenuTarget.showOriginalPage(_:))),
        ]
        view.insertItem(.separator(), at: zoom + 1)
        for (offset, (title, action)) in entries.enumerated() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = TranslateMenuTarget.shared
            view.insertItem(item, at: zoom + 2 + offset)
        }
        return self
    }
}
