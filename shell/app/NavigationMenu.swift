import AppKit

extension BrowserStore {
    func navigationMenu(back: Bool, _ show: @escaping (NSMenu) -> Void) {
        guard let view = visibleView else { return }
        view.sendDevToolsCommand("Page.getNavigationHistory", params: nil) { result, _ in
            MainActor.assumeIsolated {
                guard let data = result?.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = json["currentIndex"] as? Int,
                      let entries = json["entries"] as? [[String: Any]], entries.indices.contains(current)
                else { return }
                let slice = back ? Array(entries[..<current].reversed()) : Array(entries[(current + 1)...])
                guard !slice.isEmpty else { return }
                let menu = NSMenu()
                for entry in slice.prefix(15) {
                    guard let id = entry["id"] as? Int else { continue }
                    let url = entry["url"] as? String ?? ""
                    let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                    menu.add(String(title.prefix(60))) {
                        view.sendDevToolsCommand("Page.navigateToHistoryEntry", params: "{\"entryId\":\(id)}") { _, _ in }
                    }
                    menu.items.last?.toolTip = url
                }
                show(menu)
            }
        }
    }
}
