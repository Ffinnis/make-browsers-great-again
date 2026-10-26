import AppKit

@MainActor
final class CommandBarView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: BrowserStore
    let mode: CommandBarMode
    private let dim = CALayer()
    private let card = CommandBarCard()
    private let searchIcon = NSImageView()
    private let field = NSTextField()
    private let topRule = CALayer()
    private let bottomRule = CALayer()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let footer = Label.make(size: 11, color: .secondaryLabelColor)
    private var rows: [Row] = []
    private var items: [Item] = []
    private var actions: [CommandAction] = []
    private var selection = 0

    enum Item: Hashable {
        case go(String)
        case search(String)
        case page(HistoryItem)
        case tab(TabInfo, spaceID: UInt64)
        case space(SpaceInfo, index: Int)
        case action(String)
        case closed(TabInfo)
    }

    private enum Row {
        case header(String)
        case item(Item, index: Int)
    }

    static let debugPreset = ProcessInfo.processInfo.environment["MBGA_DEBUG_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }

    init(store: BrowserStore, mode: CommandBarMode) {
        self.store = store
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dim)

        searchIcon.image = .symbol("magnifyingglass", size: 16)
        searchIcon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(18)
        field.placeholderString = mode == .newTab ? "Search, enter a URL or type a command…" : "Enter URL…"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.focusRingType = .none
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        footer.stringValue = "↩ Open     ⌘↩ Search the web     esc Close"
        footer.alignment = .right

        addSubview(card)
        for view in [searchIcon, field, scroll, footer] as [NSView] { card.addSubview(view) }
        card.layer?.addSublayer(topRule)
        card.layer?.addSublayer(bottomRule)

        if mode == .editCurrent { field.stringValue = store.visibleTab?.url ?? "" }
        if mode == .newTab, let preset = Self.debugPreset { field.stringValue = preset }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        topRule.backgroundColor = Theme.faint(0.08).cgColor
        bottomRule.backgroundColor = Theme.faint(0.08).cgColor
    }

    func present() {
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        guard !Motion.reduced, let layer = card.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform")
        let bounds = layer.bounds
        var start = CATransform3DMakeTranslation(bounds.width * 0.015, bounds.height * 0.015, 0)
        start = CATransform3DScale(start, 0.97, 0.97, 1)
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        for animation in [fade, grow] {
            animation.duration = Motion.quick.duration
            animation.timingFunction = Motion.quick.timing
        }
        layer.add(fade, forKey: "fade")
        layer.add(grow, forKey: "grow")
        let dimFade = CABasicAnimation(keyPath: "opacity")
        dimFade.fromValue = 0
        dimFade.toValue = 1
        dimFade.duration = Motion.quick.duration
        dim.add(dimFade, forKey: "fade")
    }

    private var dismissing = false

    func dismiss(_ completion: @escaping @MainActor () -> Void) {
        dismissing = true
        guard !Motion.reduced, let layer = card.layer else {
            completion()
            return
        }
        let bounds = layer.bounds
        var end = CATransform3DMakeTranslation(bounds.width * 0.015, bounds.height * 0.015, 0)
        end = CATransform3DScale(end, 0.97, 0.97, 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.foldIn.duration)
        CATransaction.setAnimationTimingFunction(Motion.foldIn.timing)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        for (target, key) in [(layer, "opacity"), (dim, "opacity")] {
            let fade = CABasicAnimation(keyPath: key)
            fade.fromValue = target.presentation()?.opacity ?? 1
            fade.toValue = 0
            target.add(fade, forKey: "fadeOut")
            target.opacity = 0
        }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        shrink.toValue = end
        layer.add(shrink, forKey: "shrink")
        layer.transform = end
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { dismissing ? nil : super.hitTest(point) }

    private var resizeAnimated = false

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        let width: CGFloat = 620
        let listHeight = min(table.intrinsicListHeight + 12, 420)
        let hasResults = !items.isEmpty
        let height: CGFloat = 54 + (hasResults ? 1 + listHeight + 1 + 30 : 0)
        let cardFrame = NSRect(x: (bounds.width - width) / 2, y: 110, width: width, height: height)
        let animated = resizeAnimated && card.frame.height > 0 && card.frame != cardFrame && !Motion.reduced
        resizeAnimated = false
        if animated {
            Motion.animate(Motion.quick) { card.animator().frame = cardFrame }
        } else {
            card.frame = cardFrame
        }
        searchIcon.frame = NSRect(x: 16, y: 17, width: 20, height: 20)
        field.frame = NSRect(x: 46, y: 14, width: width - 62, height: 26)
        topRule.isHidden = !hasResults
        bottomRule.isHidden = !hasResults
        for part in [scroll, footer] as [NSView] {
            part.setVisible(hasResults, animated: animated)
        }
        topRule.frame = NSRect(x: 0, y: 54, width: width, height: 1)
        scroll.frame = NSRect(x: 6, y: 55, width: width - 12, height: listHeight)
        table.tableColumns.first?.width = width - 12
        bottomRule.frame = NSRect(x: 0, y: 55 + listHeight, width: width, height: 1)
        footer.frame = NSRect(x: 14, y: height - 22, width: width - 28, height: 14)
        CATransaction.commit()
    }

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    private func reload() {
        actions = CommandAction.all(for: store)
        let sections = makeSections()
        rows = []
        items = []
        for (title, sectionItems) in sections {
            if let title { rows.append(.header(title)) }
            for item in sectionItems {
                rows.append(.item(item, index: items.count))
                items.append(item)
            }
        }
        selection = 0
        table.reloadData()
        resizeAnimated = true
        needsLayout = true
    }

    private func makeSections() -> [(String?, [Item])] {
        let query = query
        guard !query.isEmpty else { return [] }
        let resolved = store.core.resolveInput(text: query)
        let isAddress = resolved != store.core.searchUrl(text: query)
        let history = store.core.suggestHistory(query: query, limit: 8)

        var tabs: [Item] = []
        var openTabs: [String: Item] = [:]
        var seen = Set<UInt64>()
        let spaces = [store.activeSpace] + store.snapshot.spaces.filter { $0.id != store.activeSpace.id }
        for space in spaces {
            for tab in space.favorites + space.pinned.compactMap(\.tab) + space.today where !seen.contains(tab.id) {
                seen.insert(tab.id)
                let item = Item.tab(tab, spaceID: space.id)
                if openTabs[tab.url] == nil { openTabs[tab.url] = item }
                if tabs.count < 5, matches(query, tab.title, tab.url) { tabs.append(item) }
            }
        }

        var top: [Item] = []
        if !isAddress, let best = history.first, best.sitePrefix {
            if let open = openTabs[best.url] {
                top.append(open)
                tabs.removeAll { $0 == open }
            } else {
                top.append(.page(best))
            }
        }
        top.append(isAddress ? .go(resolved) : .search(query))

        let spaceItems: [Item] = store.snapshot.spaces.enumerated()
            .filter { store.snapshot.spaces.count > 1 && matches(query, $0.element.name) }
            .prefix(3)
            .map { .space($0.element, index: $0.offset) }
        let actionItems: [Item] = query.count < 2 ? [] : actions.filter { $0.matches(query) }.prefix(5).map { .action($0.id) }
        let pages: [Item] = history
            .filter { page in openTabs[page.url] == nil && !top.contains(.page(page)) }
            .prefix(5)
            .map { .page($0) }
        let closed: [Item] = store.canReopen
            ? store.core.closedTabs(limit: 25).filter { matches(query, $0.title, $0.url) }.prefix(3).map { .closed($0) }
            : []
        return [(nil, top), ("Tabs", tabs), ("Spaces", spaceItems), ("Actions", actionItems),
                ("History", pages), ("Recently Closed", closed)].filter { !$0.1.isEmpty }
    }

    private func matches(_ query: String, _ fields: String...) -> Bool {
        let words = query.lowercased().split(separator: " ")
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 34
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CommandRowView()
        if case .item(_, let index) = rows[row] { view.highlighted = index == selection }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSTableCellView()
            let label = Label.make(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
            label.frame = NSRect(x: 10, y: 3, width: 300, height: 14)
            cell.addSubview(label)
            return cell
        case .item(let item, _):
            let cell = CommandItemCell()
            configure(cell, with: item)
            return cell
        }
    }

    private func configure(_ cell: CommandItemCell, with item: Item) {
        switch item {
        case .go(let url):
            cell.set(symbol: "globe", title: url, chip: "Go")
        case .search(let query):
            cell.set(symbol: "magnifyingglass", title: "Search for “\(query)”", chip: "Search")
        case .page(let page):
            let address = Self.address(page.url)
            cell.set(symbol: "clock", title: page.title.isEmpty ? address : page.title, subtitle: address)
        case .tab(let tab, let spaceID):
            let subtitle = spaceID != store.activeSpace.id
                ? store.snapshot.spaces.first { $0.id == spaceID }.map { "\($0.icon) \($0.name)" } ?? tab.host
                : tab.host
            cell.set(image: FaviconCache.shared.image(for: tab), title: tab.displayTitle, subtitle: subtitle,
                     chip: "Switch to Tab")
        case .space(let space, let index):
            cell.set(emoji: space.icon.isEmpty ? "•" : space.icon, title: space.name, chip: index < 9 ? "⌃\(index + 1)" : nil)
        case .action(let id):
            if let action = actions.first(where: { $0.id == id }) {
                cell.set(symbol: action.symbol, title: action.title, chip: action.shortcut)
            }
        case .closed(let tab):
            cell.set(image: FaviconCache.shared.image(for: tab), title: tab.displayTitle, subtitle: tab.host,
                     chip: "Reopen", dimImage: true)
        }
    }

    private static func address(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        let old = selection
        selection = min(max(selection + offset, 0), items.count - 1)
        guard old != selection else { return }
        for (row, entry) in rows.enumerated() {
            guard case .item(_, let index) = entry, index == old || index == selection else { continue }
            FillLayer.animated(Motion.quick) {
                (table.rowView(atRow: row, makeIfNecessary: false) as? CommandRowView)?.highlighted = index == selection
            }
            if index == selection { table.scrollRowToVisible(row) }
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), case .item(_, let index) = rows[row] else { return }
        selection = index
        commit()
    }

    private func commit() {
        guard items.indices.contains(selection) else {
            if !query.isEmpty { store.submit(field.stringValue, mode: mode) }
            return
        }
        switch items[selection] {
        case .go(let url):
            store.submit(url, mode: mode)
        case .search(let query):
            store.search(query, mode: mode)
        case .page(let page):
            store.submit(page.url, mode: mode)
        case .tab(let tab, let spaceID):
            store.commandBar = nil
            store.select(tab.id, in: spaceID)
        case .space(let space, _):
            store.commandBar = nil
            store.activateSpace(space.id)
        case .action(let id):
            store.commandBar = nil
            actions.first { $0.id == id }?.run()
        case .closed(let tab):
            store.commandBar = nil
            store.reopenClosedTab(tab.id)
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true, !query.isEmpty {
                store.search(query, mode: mode)
            } else {
                commit()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            store.commandBar = nil
        default:
            return false
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { store.commandBar = nil }
    }
}

private final class CommandBarCard: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.isDark
        layer.backgroundColor = Theme.cardFill.cgColor
        layer.borderWidth = 0.5
        layer.borderColor = Theme.faint(dark ? 0.14 : 0.1).cgColor
        layer.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.22).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 32
        layer.shadowOffset = CGSize(width: 0, height: -14)
    }

    override func mouseDown(with event: NSEvent) {}
}

private final class CommandRowView: NSTableRowView {
    private let fill = FillLayer()

    var highlighted = false {
        didSet { needsDisplay = true; updateLayer() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        fill.paint(fill: highlighted ? Theme.faint(0.08) : nil, in: effectiveAppearance)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class CommandItemCell: NSTableCellView {
    private let icon = NSImageView()
    private let emoji = Label.make(size: 13)
    private let title = Label.make()
    private let subtitle = Label.make(color: .secondaryLabelColor)
    private let chip = Label.chip()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        emoji.alignment = .center
        for view in [icon, emoji, title, subtitle, chip] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        chip.layer?.backgroundColor = Theme.faint(0.06).cgColor
    }

    private func set(title text: String, subtitle sub: String?, chip label: String?) {
        title.stringValue = text
        subtitle.stringValue = sub ?? ""
        subtitle.isHidden = sub == nil
        chip.stringValue = label ?? ""
        chip.isHidden = label == nil
        needsLayout = true
    }

    func set(symbol: String, title: String, subtitle: String? = nil, chip: String? = nil) {
        icon.image = .symbol(symbol, size: 13, weight: .regular)
        icon.alphaValue = 1
        icon.isHidden = false
        emoji.isHidden = true
        set(title: title, subtitle: subtitle, chip: chip)
    }

    func set(image: NSImage, title: String, subtitle: String? = nil, chip: String? = nil, dimImage: Bool = false) {
        icon.image = image
        icon.alphaValue = dimImage ? 0.7 : 1
        icon.isHidden = false
        emoji.isHidden = true
        set(title: title, subtitle: subtitle, chip: chip)
    }

    func set(emoji text: String, title: String, chip: String? = nil) {
        emoji.stringValue = text
        emoji.isHidden = false
        icon.isHidden = true
        set(title: title, subtitle: nil, chip: chip)
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        icon.frame = NSRect(x: 10, y: midY - 8, width: 16, height: 16)
        emoji.frame = NSRect(x: 8, y: midY - 9, width: 20, height: 18)
        let chipWidth: CGFloat = chip.isHidden ? 0 : chip.textWidth + 12
        chip.frame = NSRect(x: bounds.width - 10 - chipWidth, y: midY - 9, width: chipWidth, height: 18)
        let textX: CGFloat = 36
        let available = bounds.width - textX - chipWidth - 18
        let titleWidth = min(title.textWidth, subtitle.isHidden ? available : available * 0.62)
        title.frame = NSRect(x: textX, y: midY - 8, width: max(titleWidth, 0), height: 16)
        let subX = textX + titleWidth + 8
        subtitle.frame = NSRect(x: subX, y: midY - 8, width: max(textX + available - subX, 0), height: 16)
    }
}

private extension NSTableView {
    var intrinsicListHeight: CGFloat {
        guard numberOfRows > 0 else { return 0 }
        return rect(ofRow: numberOfRows - 1).maxY
    }
}

struct CommandAction {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String?
    var keywords: [String] = []
    let run: () -> Void

    func matches(_ query: String) -> Bool {
        let words = (title + " " + keywords.joined(separator: " ")).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return query.lowercased().split(separator: " ").allSatisfy { q in words.contains { $0.hasPrefix(q) } }
    }

    @MainActor
    static func all(for store: BrowserStore) -> [Self] {
        var list: [Self] = []
        if let tab = store.visibleTab {
            let space = store.activeSpace
            let pinned = store.isPinned(tab.id, in: space) || store.isFavorite(tab.id, in: space)
            list += [
                Self(id: "pin", title: pinned ? "Unpin Tab" : "Pin Tab", symbol: pinned ? "pin.slash" : "pin",
                     shortcut: "⌘D") { store.togglePin(tab.id) },
                Self(id: "favorite", title: "Add to Favorites", symbol: "star", keywords: ["fav"]) {
                    store.addFavorite(tab.id)
                },
                Self(id: "copy", title: "Copy URL", symbol: "link", shortcut: "⇧⌘C", keywords: ["link", "share"]) {
                    store.copyVisibleURL()
                },
                Self(id: "reload", title: "Reload Page", symbol: "arrow.clockwise", shortcut: "⌘R", keywords: ["refresh"]) {
                    store.reload()
                },
                Self(id: "duplicate", title: "Duplicate Tab", symbol: "plus.square.on.square") {
                    store.duplicate(tab, in: space)
                },
                Self(id: "little", title: "Open in Little Window", symbol: "macwindow.on.rectangle",
                     keywords: ["pop", "out", "float", "window"]) {
                    store.openInLittleWindow(tab.id)
                },
                Self(id: "close", title: pinned ? "Unload Tab" : "Close Tab", symbol: "xmark", shortcut: "⌘W") {
                    store.closeAsking(tab.id)
                },
                Self(id: "devtools", title: "Developer Tools", symbol: "hammer", shortcut: "⌥⌘I", keywords: ["inspect", "console"]) {
                    store.showDevTools()
                },
                Self(id: "console", title: "JavaScript Console", symbol: "terminal", shortcut: "⌥⌘J",
                     keywords: ["devtools", "js", "log"]) {
                    store.openDevTools()
                },
                Self(id: "network-panel", title: "Network Requests", symbol: "arrow.up.arrow.down",
                     keywords: ["devtools", "requests", "fetch", "xhr"]) {
                    store.showInspector(.network)
                },
                Self(id: "chrome-devtools", title: "Chrome DevTools", symbol: "wrench.and.screwdriver", shortcut: "⇧⌥⌘I",
                     keywords: ["inspect", "devtools"]) {
                    store.openChromeDevTools()
                },
            ]
            if let site = tab.site, store.blockAds {
                list.append(Self(id: "ads", title: tab.adsAllowed ? "Block Ads on \(site)" : "Allow Ads on \(site)",
                                 symbol: "shield.lefthalf.filled", keywords: ["adblock", "trackers", "blocker"]) {
                        store.setAdsAllowed(!tab.adsAllowed, for: tab)
                    })
            }
            list.append(Self(id: "tab-awake", title: tab.alwaysAwake ? "Let This Tab Sleep" : "Keep This Tab Always Awake",
                             symbol: tab.alwaysAwake ? "moon.zzz" : "sun.max", keywords: ["sleep", "awake", "live", "unload"]) {
                    store.setAlwaysAwake(!tab.alwaysAwake, for: tab.id)
                })
            if let site = tab.site {
                list.append(Self(id: "awake", title: tab.keepAwake ? "Let \(site) Sleep" : "Keep \(site) Awake",
                                 symbol: tab.keepAwake ? "moon.zzz" : "sun.max", keywords: ["sleep", "awake"]) {
                        store.setKeepAwake(!tab.keepAwake, for: tab)
                    })
            }
        }
        list += [
            Self(id: "new-space", title: "New Space…", symbol: "square.stack", shortcut: "⇧⌘N") {
                store.spaceEditor = SpaceEditorRequest(spaceID: nil)
            },
            Self(id: "edit-space", title: "Edit Space…", symbol: "pencil", keywords: ["rename", "color", "icon"]) {
                store.spaceEditor = SpaceEditorRequest(spaceID: store.activeSpace.id)
            },
            Self(id: "new-folder", title: "New Folder", symbol: "folder.badge.plus", shortcut: "⌥⌘N") {
                store.newFolder()
            },
            Self(id: "clear", title: "Clear Today Tabs", symbol: "archivebox", shortcut: "⇧⌘K", keywords: ["archive", "clean", "tidy"]) {
                store.clearToday(store.activeSpace.id)
            },
            Self(id: "focus", title: store.layout == .focus ? "Leave Focus Mode" : "Focus Mode", symbol: "rectangle.inset.filled",
                 shortcut: "⌘S", keywords: ["hide", "sidebar", "zen"]) {
                store.toggleSidebar()
            },
            Self(id: "compact", title: store.layout == .compact ? "Full Sidebar" : "Compact Sidebar",
                 symbol: "sidebar.squares.left", keywords: ["rail", "icons", "narrow", "layout"]) {
                store.setLayout(store.layout == .compact ? .full : .compact)
            },
            Self(id: "import", title: "Import from Another Browser…", symbol: "square.and.arrow.down", keywords: ["chrome", "arc", "safari"]) {
                store.importSheet = ImportRequest(firstLaunch: false)
            },
            Self(id: "import-sign-ins", title: "Import Sign-ins…", symbol: "person.badge.key",
                 keywords: ["cookies", "logged out", "login", "arc", "chrome", "firefox"]) {
                store.openSettings?(.privacy)
            },
            Self(id: "block-ads", title: store.blockAds ? "Turn Off Ad Blocking" : "Block Ads and Trackers",
                 symbol: "shield", keywords: ["adblock", "trackers", "privacy"]) {
                store.setBlockAds(!store.blockAds)
            },
            Self(id: "my-filters", title: "Edit My Filters…", symbol: "line.3.horizontal.decrease.circle",
                 keywords: ["adblock", "rules", "custom", "block"]) {
                NSWorkspace.shared.open(URL(fileURLWithPath: store.core.userFiltersPath()))
            },
            Self(id: "extensions", title: "Extensions…", symbol: "puzzlepiece.extension",
                 keywords: ["chrome", "web store", "add-ons", "ublock", "install"]) {
                store.showExtensions()
            },
            Self(id: "reload-filters", title: "Reload Filters", symbol: "arrow.triangle.2.circlepath",
                 keywords: ["adblock", "rules", "lists"]) {
                Task {
                    let loaded = await AdBlocking.reload(core: store.core)
                    store.showToast(Toast(message: loaded ? "Filters reloaded" : "Ad blocking is off",
                                          symbol: "shield.lefthalf.filled"))
                    if loaded { store.reload() }
                }
            },
            Self(id: "update", title: Updater.shared.readyVersion.map { "Restart to Update to \($0)" } ?? "Check for Updates",
                 symbol: "arrow.down.circle", keywords: ["upgrade", "version", "new", "relaunch"]) {
                if Updater.shared.readyVersion != nil {
                    Updater.shared.restartToUpdate()
                } else {
                    Updater.shared.check(userInitiated: true)
                }
            },
            Self(id: "clear-history", title: "Clear History", symbol: "clock.arrow.circlepath", keywords: ["forget", "privacy"]) {
                store.core.clearHistory()
                store.showToast(Toast(message: "History cleared", symbol: "clock.arrow.circlepath"))
            },
        ]
        list += developerActions(for: store)
        if store.canReopen {
            list.append(Self(id: "reopen", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T",
                             keywords: ["undo", "restore"]) { store.undoClose() })
        }
        let matchPage = UserDefaults.standard.bool(forKey: TintStyle.matchPageKey)
        list.append(Self(id: "match-page", title: matchPage ? "Use Space Colour" : "Match Page Colour",
                         symbol: "eyedropper", keywords: ["theme", "tint", "color", "colour"]) {
                UserDefaults.standard.set(!matchPage, forKey: TintStyle.matchPageKey)
            })
        for style in TintStyle.allCases {
            list.append(Self(id: "tint-\(style.rawValue)", title: "Sidebar Colour: \(style.title)", symbol: "paintpalette",
                             keywords: ["theme", "tint", "color", "appearance"]) {
                    UserDefaults.standard.set(style.rawValue, forKey: TintStyle.defaultsKey)
                })
        }
        return list
    }

    @MainActor
    private static func developerActions(for store: BrowserStore) -> [Self] {
        var list = [
            Self(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,", keywords: ["preferences", "options"]) {
                store.openSettings?(nil)
            },
            Self(id: "developer-mode", title: DeveloperSettings.enabled ? "Turn Off Developer Mode" : "Turn On Developer Mode",
                 symbol: "hammer", keywords: ["dev", "toolbar", "localhost"]) {
                UserDefaults.standard.set(!DeveloperSettings.enabled, forKey: DeveloperSettings.enabledKey)
            },
        ]
        guard DeveloperSettings.enabled, store.visibleTab != nil else { return list }
        let state = store.visibleDevState
        let keywords = ["dev", "developer"]
        list += [
            Self(id: "dev-toolbar", title: store.developerToolbarShown ? "Hide Developer Toolbar" : "Show Developer Toolbar",
                 symbol: "wrench.and.screwdriver", shortcut: "⇧⌘D", keywords: keywords) { store.toggleDeveloperToolbar() },
            Self(id: "hard-reload", title: "Reload Without Cache", symbol: "arrow.clockwise", shortcut: "⇧⌘R",
                 keywords: keywords + ["hard", "refresh", "empty"]) { store.hardReload() },
            Self(id: "pick", title: "Pick an Element", symbol: "cursorarrow.rays", shortcut: "⌥⌘C",
                 keywords: keywords + ["inspect", "select"]) { store.togglePicking() },
            Self(id: "screenshot", title: "Screenshot the Whole Page", symbol: "camera.viewfinder",
                 keywords: keywords + ["capture", "full", "image"]) { store.screenshotPage() },
            Self(id: "view-source", title: "View Page Source", symbol: "chevron.left.forwardslash.chevron.right", shortcut: "⌥⌘U",
                 keywords: keywords + ["html", "code"]) { store.viewSource() },
            Self(id: "clear-site", title: "Clear Site Data and Reload", symbol: "trash",
                 keywords: keywords + ["cookies", "storage", "cache", "reset"]) { store.clearSiteData() },
            Self(id: "cache", title: state.cacheDisabled ? "Enable Cache" : "Disable Cache", symbol: "externaldrive",
                 keywords: keywords + ["network"]) { store.updateDev { $0.cacheDisabled.toggle() } },
            Self(id: "scripts", title: state.scriptsDisabled ? "Enable JavaScript" : "Disable JavaScript", symbol: "curlybraces",
                 keywords: keywords + ["js"]) { store.toggleScripts() },
        ]
        for scheme in [ColorSchemePreview.dark, .light, .system] where scheme != state.colorScheme {
            list.append(Self(id: "scheme-\(scheme.rawValue)", title: "Preview Colour Scheme: \(scheme.title)", symbol: scheme.symbol,
                             keywords: keywords + ["dark", "light", "mode", "appearance", "color"]) {
                    store.updateDev { $0.colorScheme = scheme }
                })
        }
        for preset in DevicePreset.all where preset != state.device {
            list.append(Self(id: "device-\(preset.name)", title: "Preview on \(preset.name)", symbol: preset.symbol,
                             keywords: keywords + ["device", "responsive", "mobile", "viewport"]) { store.setDevice(preset) })
        }
        if state.device != nil {
            list.append(Self(id: "device-off", title: "Stop Device Preview", symbol: "rectangle",
                             keywords: keywords + ["responsive", "desktop"]) { store.setDevice(nil) })
        }
        for preset in NetworkPreset.allCases where preset != state.network {
            list.append(Self(id: "network-\(preset)", title: "Network: \(preset.title)", symbol: "wifi",
                             keywords: keywords + ["throttle", "slow", "offline"]) { store.updateDev { $0.network = preset } })
        }
        return list
    }
}
