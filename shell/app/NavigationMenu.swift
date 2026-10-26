import AppKit

extension BrowserStore {
    func navigationMenu(back: Bool, _ show: @escaping (NSMenu) -> Void) {
        guard let view = visibleView else { return }
        var current = -1
        let entries = view.navigationEntries(&current)
        guard entries.indices.contains(current) else { return }
        let slice = back ? Array(entries[..<current].reversed()) : Array(entries[(current + 1)...])
        guard !slice.isEmpty else { return }
        let menu = NSMenu()
        for (index, entry) in slice.prefix(15).enumerated() {
            let title = entry.title.isEmpty ? entry.url : entry.title
            let item = menu.add(String(title.prefix(60))) { view.go(by: back ? -(index + 1) : index + 1) }
            item.toolTip = entry.url
        }
        show(menu)
    }
}
