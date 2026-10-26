import AppKit

extension BrowserStore {
    private static let searchEngineNames = [
        "google": "Google", "duckduckgo": "DuckDuckGo", "bing": "Bing", "kagi": "Kagi", "ecosia": "Ecosia",
        "yandex": "Yandex", "brave": "Brave", "startpage": "Startpage", "perplexity": "Perplexity", "yahoo": "Yahoo",
    ]

    func toggleMute(_ tabID: UInt64) {
        guard let tab = core.tab(id: tabID) else { return }
        core.setMuted(id: tabID, muted: !tab.muted)
        Self.holder(of: tabID)?.views[tabID]?.audioMuted = !tab.muted
        refresh()
    }

    func closeVisibleTab() {
        if let id = visibleTabID { closeAsking(id) }
    }

    func closeAsking(_ tabID: UInt64) {
        guard let view = views[tabID] else { return close(tabID) }
        view.closeAskingPage { [weak self] closed in
            if closed { self?.close(tabID) }
        }
    }

    func viewSource() {
        guard let url = visibleTab?.url, !url.isEmpty, !url.hasPrefix("view-source:") else { return }
        _ = core.openTab(spaceId: activeSpace.id, url: "view-source:" + url, activate: true)
        refresh()
    }

    func openVisible(in app: URL) {
        guard let url = visibleTab?.url, let page = URL(string: url) else { return }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    nonisolated func webView(_ view: MBWebView, requestsNewWindowWithURL url: String) {
        MainActor.assumeIsolated {
            let space = space(owning: view.tabID)?.id ?? activeSpace.id
            _ = (NSApp.delegate as? AppDelegate)?.openWindow(url: url, in: space)
        }
    }

    nonisolated func searchEngineName(for view: MBWebView) -> String? {
        MainActor.assumeIsolated {
            guard let host = URL(string: core.searchUrl(text: "mbga"))?.host?.lowercased() else { return nil }
            let labels = host.split(separator: ".").map(String.init)
            return labels.lazy.compactMap { Self.searchEngineNames[$0] }.first
        }
    }

    nonisolated func webView(_ view: MBWebView, searchesFor text: String) {
        MainActor.assumeIsolated {
            webView(view, requestsNewTabWithURL: core.searchUrl(text: text), foreground: true)
        }
    }

    nonisolated func webView(
        _ view: MBWebView,
        requestsCredentialsForHost host: String,
        realm: String,
        proxy: Bool,
        reply: @escaping (String?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let window = view.window ?? window else { return reply(nil, nil) }
            SignInPrompt(host: host, realm: realm, proxy: proxy).show(in: window, reply: reply)
        }
    }
}

@MainActor
private struct SignInPrompt {
    let host: String
    let realm: String
    let proxy: Bool

    func show(in window: NSWindow, reply: @escaping (String?, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = proxy ? "Sign in to proxy \(host)" : "Sign in to \(host)"
        alert.informativeText = realm.isEmpty ? "" : "The site says: “\(realm)”"
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        user.nextKeyView = password
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                reply(user.stringValue, password.stringValue)
            } else {
                reply(nil, nil)
            }
        }
    }
}

extension AppDelegate {
    @discardableResult
    func openWindow(url: String? = nil, in space: UInt64? = nil) -> BrowserStore {
        let store = BrowserStore(core: core, newWindow: true)
        let window = makeWindow(for: store)
        store.refresh()
        window.makeKeyAndOrderFront(nil)
        if let url, let space, let id = core.openTab(spaceId: space, url: url, activate: false) {
            store.select(id, in: space)
        } else if let url {
            store.openFromSystem(url)
        }
        return store
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let store = BrowserStore.front, store.window === notification.object as? NSWindow else { return }
        store.windowExitedFullscreen()
    }
}

@MainActor
final class PageCommands: NSObject, NSMenuItemValidation {
    static let shared = PageCommands()
    private var mouseButtonMonitor: Any?

    private var store: BrowserStore? { BrowserStore.front }

    private var page: MBWebView? {
        if let key = NSApp.keyWindow, key !== store?.window, let view = key.contentView?.firstSubview(of: MBWebView.self) {
            return view
        }
        return store?.visibleView
    }

    @objc func stopLoading(_ sender: Any?) { page?.stopLoading() }
    @objc func printPage(_ sender: Any?) { page?.printPage() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let page else { return false }
        return item.action != #selector(stopLoading(_:)) || store?.navStates[page.tabID]?.isLoading == true
    }

    func monitorMouseButtons() {
        mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            guard event.buttonNumber == 3 || event.buttonNumber == 4,
                  let content = event.window?.contentView,
                  let page = Self.webView(in: content, at: event.locationInWindow)
            else { return event }
            if event.buttonNumber == 3 { page.goBack() } else { page.goForward() }
            return nil
        }
    }

    private static func webView(in content: NSView, at point: NSPoint) -> MBWebView? {
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view, !(current is MBWebView) { view = current.superview }
        return view as? MBWebView
    }
}

@MainActor
extension NSMenu {
    func addingPageItems() -> NSMenu {
        let commands = PageCommands.shared
        commands.monitorMouseButtons()
        MBEngine.setCredentialsHandler { host, realm, proxy, window, reply in
            MainActor.assumeIsolated {
                guard let window = window ?? NSApp.keyWindow else { return reply(nil, nil) }
                SignInPrompt(host: host, realm: realm, proxy: proxy).show(in: window, reply: reply)
            }
        }
        let history = HistoryMenu.shared
        insert("Open File…", #selector(HistoryMenu.openFile(_:)), "o", target: history,
               in: "File", after: "Open Location…")
        insert("Save Page As…", #selector(HistoryMenu.savePage(_:)), "s", [.command, .shift], target: history,
               in: "File", after: nil)
        insert("Print…", #selector(PageCommands.printPage(_:)), "p", target: commands,
               in: "File", after: "Save Page As…")
        insert("Downloads", #selector(HistoryMenu.showDownloads(_:)), "l", [.command, .option], target: history,
               in: "Window", after: nil)
        if let menu = items.first(where: { $0.title == "History" })?.submenu { history.install(in: menu) }
        insert("Paste and Match Style", Selector(("pasteAndMatchStyle:")), "v", [.command, .option, .shift],
               target: nil, in: "Edit", after: "Paste")
        insert("Stop", #selector(PageCommands.stopLoading(_:)), ".", target: commands,
               in: "View", after: "Reload Without Cache")
        insert("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+", target: NSApp.delegate as AnyObject?,
               in: "View", after: "Zoom In", hidden: true)
        insert("Next Tab", #selector(AppDelegate.nextTab(_:)), "}", target: NSApp.delegate as AnyObject?,
               in: "Tabs", after: "Previous Tab", hidden: true)
        insert("Previous Tab", #selector(AppDelegate.previousTab(_:)), "{", target: NSApp.delegate as AnyObject?,
               in: "Tabs", after: "Previous Tab", hidden: true)
        return self
    }

    private func insert(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject?,
        in menuTitle: String,
        after sibling: String?,
        hidden: Bool = false
    ) {
        guard let menu = items.first(where: { $0.title == menuTitle })?.submenu else { return }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.isHidden = hidden
        item.allowsKeyEquivalentWhenHidden = hidden
        if let sibling, let index = menu.items.lastIndex(where: { $0.title == sibling }) {
            menu.insertItem(item, at: index + 1)
        } else {
            if sibling == nil, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            menu.addItem(item)
        }
    }
}
