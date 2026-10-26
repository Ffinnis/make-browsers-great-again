import AppKit

@MainActor
enum Menus {
    static func tab(_ tab: TabInfo, in space: SpaceInfo, store: BrowserStore) -> NSMenu {
        let menu = NSMenu()
        let favorite = store.isFavorite(tab.id, in: space)
        let pinned = store.isPinned(tab.id, in: space)
        if favorite {
            menu.add("Remove from Favorites") { store.togglePin(tab.id, in: space) }
        } else {
            menu.add("Add to Favorites") { store.addFavorite(tab.id) }
            menu.add(pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id, in: space) }
        }
        let others = store.snapshot.spaces.filter { $0.id != space.id }
        if !favorite, !others.isEmpty {
            menu.addSubmenu(titled: "Move to Space") { sub in
                for other in others {
                    sub.add("\(other.icon) \(other.name)") { store.move(tab.id, to: .today(spaceId: other.id), index: 0) }
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Keep Tab Always Awake", state: tab.alwaysAwake) { store.setAlwaysAwake(!tab.alwaysAwake, for: tab.id) }
        if let site = tab.site {
            menu.add("Keep \(site) Awake", state: tab.keepAwake) { store.setKeepAwake(!tab.keepAwake, for: tab) }
            if store.blockAds {
                menu.add("Allow Ads on \(site)", state: tab.adsAllowed) { store.setAdsAllowed(!tab.adsAllowed, for: tab) }
            }
        }
        menu.add("Copy Link") { store.copyLink(tab.url) }
        menu.add("Duplicate") { store.duplicate(tab, in: space) }
        menu.add(store.isInLittleWindow(tab.id) ? "Show Little Window" : "Open in Little Window") {
            store.openInLittleWindow(tab.id)
        }
        menu.addItem(.separator())
        if tab.live, !(favorite || pinned) {
            menu.add("Sleep Tab") { store.sleep(tab.id) }
        }
        menu.add(favorite || pinned ? "Unload Tab" : "Close Tab") { store.closeAsking(tab.id) }
        return menu
    }

    static func folder(_ row: PinnedRow, in space: SpaceInfo, store: BrowserStore) -> NSMenu {
        let menu = NSMenu()
        menu.add("Rename") { store.renamingFolder = row.id }
        menu.add("New Folder Inside") { store.newFolder(in: space.id, parent: row.id) }
        menu.addItem(.separator())
        menu.add("Delete Folder and Tabs") { store.deleteFolder(row.id) }
        return menu
    }

    static func space(_ space: SpaceInfo, store: BrowserStore) -> NSMenu {
        let menu = NSMenu()
        menu.add("Edit Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
        menu.add("New Folder") { store.newFolder(in: space.id) }
        menu.addSubmenu(titled: "Profile") { sub in
            for profile in store.snapshot.profiles {
                sub.add(profile.name, state: space.profileId == profile.id) {
                    store.setProfile(profile.id, for: space.id)
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Delete Space", enabled: store.snapshot.spaces.count > 1) { store.deleteSpace(space.id) }
        return menu
    }

    static func newItem(store: BrowserStore) -> NSMenu {
        let menu = NSMenu()
        menu.add("New Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: nil) }
        menu.add("New Folder") { store.newFolder() }
        return menu
    }
}
