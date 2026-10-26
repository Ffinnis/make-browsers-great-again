import AppKit

extension Snapshot {
    func seen(fromPrivateSpace space: UInt64?) -> Snapshot {
        var seen = self
        if let space, let own = spaces.first(where: { $0.id == space }) {
            seen.spaces = [own]
            seen.activeSpace = space
        } else {
            seen.spaces = spaces.filter { !$0.ephemeral }
        }
        return seen
    }
}

extension BrowserStore {
    var isPrivate: Bool { privateSpace != nil }

    func tintColors(matchPage: Bool, dark: Bool) -> [UInt32] {
        var colors = snapshot.spaces.map(\.color)
        guard matchPage, !isPrivate, colors.indices.contains(activeSpaceIndex),
              let site = visibleTab?.site, let page = pageColors[site],
              dark ? page.luminance <= 0.7 : page.luminance >= 0.2
        else { return colors }
        colors[activeSpaceIndex] = page.hex
        return colors
    }

    func closedTabs(limit: UInt32) -> [TabInfo] {
        core.closedTabs(limit: limit, privateSpace: privateSpace)
    }

    func openInPrivateSpace(_ url: String) {
        guard let privateSpace, let id = core.openTab(spaceId: privateSpace, url: url, activate: false) else { return }
        select(id, in: privateSpace)
        window?.makeKeyAndOrderFront(nil)
    }

    func discardPrivateSpace() {
        guard let privateSpace else { return }
        let profile = core.snapshot().spaces.first { $0.id == privateSpace }?.profileId
        let path = profile.map { core.profileDir(profileId: $0) }
        _ = core.closePrivateSpace(id: privateSpace)
        if let path { MBEngine.forgetProfilePath(path) }
    }
}

extension AppDelegate {
    @objc func newPrivateWindow(_ sender: Any?) { openPrivateWindow().commandBar = .newTab }

    @discardableResult
    func openPrivateWindow() -> BrowserStore {
        let store = BrowserStore(core: core, newWindow: true, privateSpace: core.openPrivateSpace())
        let window = makeWindow(for: store)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "MBGA Private"
        store.refresh()
        window.makeKeyAndOrderFront(nil)
        return store
    }
}

extension NSMenu {
    func addingPrivateWindowItem(target: AppDelegate) -> NSMenu {
        guard let file = items.first(where: { $0.title == "File" })?.submenu else { return self }
        let after = file.items.firstIndex { $0.action == #selector(AppDelegate.newWindow(_:)) }
        let item = NSMenuItem(title: "New Private Window", action: #selector(AppDelegate.newPrivateWindow(_:)), keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command, .option, .shift]
        item.target = target
        file.insertItem(item, at: after.map { $0 + 1 } ?? 0)
        return self
    }
}
