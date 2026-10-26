import AppKit
import UniformTypeIdentifiers

@MainActor
final class HistoryMenu: NSObject, NSMenuDelegate {
    static let shared = HistoryMenu()
    private static let dynamicTag = 7701
    private static let recentCount = 15

    private var store: BrowserStore? { BrowserStore.front }

    func install(in menu: NSMenu) {
        menu.delegate = self
        menu.addItem(.separator())
        let search = NSMenuItem(title: "Search History…", action: #selector(searchHistory(_:)), keyEquivalent: "y")
        search.target = self
        menu.addItem(search)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.dynamicTag {
            menu.removeItem(item)
        }
        guard let store else { return }
        let closed = store.canReopen ? store.core.closedTabs(limit: 10) : []
        let recentlyClosed = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        recentlyClosed.tag = Self.dynamicTag
        recentlyClosed.submenu = NSMenu(title: "Recently Closed")
        recentlyClosed.isEnabled = !closed.isEmpty
        for tab in closed {
            let item = entry(tab.displayTitle, action: #selector(reopen(_:)), value: tab.id)
            item.image = FaviconCache.shared.image(for: tab)
            recentlyClosed.submenu?.addItem(item)
        }
        menu.addItem(recentlyClosed)
        let pages = store.core.recentHistory(limit: UInt32(Self.recentCount))
        if !pages.isEmpty {
            let separator = NSMenuItem.separator()
            separator.tag = Self.dynamicTag
            menu.addItem(separator)
        }
        for page in pages {
            let title = page.title.isEmpty ? page.url : page.title
            let item = entry(String(title.prefix(60)), action: #selector(openPage(_:)), value: page.url)
            item.tag = Self.dynamicTag
            item.toolTip = page.url
            menu.addItem(item)
        }
    }

    private func entry(_ title: String, action: Selector, value: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    @objc func searchHistory(_ sender: Any?) { store?.commandBar = .newTab }

    @objc private func reopen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UInt64 { store?.reopenClosedTab(id) }
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? String { store?.openFromSystem(url) }
    }

    @objc func showDownloads(_ sender: Any?) {
        if let window = store?.window { DownloadsButton.toggle(in: window) }
    }

    @objc func openFile(_ sender: Any?) {
        guard let store, let window = store.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.html, .pdf, .image, .svg, .plainText, .xml, .webArchive, .json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls { store.openFromSystem(url.absoluteString) }
        }
    }

    @objc func savePage(_ sender: Any?) {
        guard let store, let window = store.window, let view = store.visibleView, let tab = store.visibleTab,
              !tab.url.isEmpty else { return }
        view.sendDevToolsCommand("Page.captureSnapshot", params: "{\"format\":\"mhtml\"}") { result, _ in
            guard let result, let data = result.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let snapshot = json["data"] as? String
            else {
                view.saveURLAs(tab.url)
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.fileName(for: tab) + ".mhtml"
            panel.allowedContentTypes = [UTType(filenameExtension: "mhtml") ?? .data]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? Data(snapshot.utf8).write(to: url)
            }
        }
    }

    private static func fileName(for tab: TabInfo) -> String {
        let name = tab.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Page" : String(name.prefix(80))
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
