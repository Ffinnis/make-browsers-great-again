import AppKit

extension BrowserStore {
    private static let searchEngineNames = [
        "google": "Google", "duckduckgo": "DuckDuckGo", "bing": "Bing", "kagi": "Kagi", "ecosia": "Ecosia",
        "yandex": "Yandex", "brave": "Brave", "startpage": "Startpage", "perplexity": "Perplexity", "yahoo": "Yahoo",
    ]

    nonisolated func webView(_ view: MBWebView, requestsNewWindowWithURL url: String) {
        MainActor.assumeIsolated {
            _ = (NSApp.delegate as? AppDelegate)?.openWindow(url: url)
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
}

extension AppDelegate {
    @discardableResult
    func openWindow(url: String? = nil) -> BrowserStore {
        let store = BrowserStore(core: core, newWindow: true)
        let window = makeWindow(for: store)
        store.refresh()
        window.makeKeyAndOrderFront(nil)
        if let url { store.openFromSystem(url) }
        return store
    }
}
