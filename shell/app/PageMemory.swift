import AppKit

extension BrowserStore {
    func goBack(_ view: MBWebView) {
        if view.canGoBack { return view.goBack() }
        guard let current = core.tab(id: view.tabID)?.url,
              let url = core.popRestoredBack(id: view.tabID, current: current) else { return }
        view.replaceURL(url)
    }

    func goForward(_ view: MBWebView) {
        if view.canGoForward { return view.goForward() }
        if let url = core.popRestoredForward(id: view.tabID) { view.loadURL(url) }
    }

    func adjustedNav(_ tabID: UInt64, _ state: NavState) -> NavState {
        let restored = core.restoredNav(id: tabID)
        return NavState(isLoading: state.isLoading, canGoBack: state.canGoBack || restored.back,
                        canGoForward: state.canGoForward || restored.forward)
    }

    func rememberPage(_ view: MBWebView) {
        restoreScroll(view)
        recordNavigation(view)
    }

    private func recordNavigation(_ view: MBWebView) {
        var current = -1
        let urls = view.navigationEntries(&current).map(\.url)
        guard urls.indices.contains(current) else { return }
        core.recordNavigation(id: view.tabID, url: urls[current], back: Array(urls[..<current]),
                              forward: Array(urls[(current + 1)...]))
        webView(view, didChangeLoading: navStates[view.tabID]?.isLoading ?? false,
                canGoBack: view.canGoBack, canGoForward: view.canGoForward)
    }

    private func restoreScroll(_ view: MBWebView) {
        guard let y = core.takeRestoredScroll(id: view.tabID), y > 0 else { return }
        view.runScript("scrollTo(0, \(Int(y)))")
    }

    nonisolated func webView(_ view: MBWebView, didReportScroll scroll: Double, editing: Bool) {
        MainActor.assumeIsolated { core.setPageReport(id: view.tabID, scrollY: scroll, editing: editing) }
    }
}
