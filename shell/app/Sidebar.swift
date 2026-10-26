import AppKit

@MainActor
final class SidebarView: FlippedView {
    private let store: BrowserStore
    private let toolbar: SidebarToolbarView
    private let address: AddressPillView
    private let favorites: FavoritesGridView
    private let pager: SpacePagerView
    private let player: MiniPlayerView
    private let updateCard = UpdateCardView()
    private let bottom: SidebarBottomBar
    private var shownSpace: UInt64

    init(store: BrowserStore) {
        self.store = store
        toolbar = SidebarToolbarView(store: store)
        address = AddressPillView(store: store)
        favorites = FavoritesGridView(store: store)
        pager = SpacePagerView(store: store)
        player = MiniPlayerView(store: store)
        bottom = SidebarBottomBar(store: store)
        shownSpace = store.snapshot.activeSpace
        super.init(frame: .zero)
        for view in [toolbar, address, favorites, pager, player, updateCard, bottom] as [NSView] { addSubview(view) }
        player.isHidden = store.mediaTab == nil
        updateCard.isHidden = Self.readyUpdate == nil
        if let version = Self.readyUpdate { updateCard.update(version: version) }
        store.pager.sidebar = self
        store.observe(self) { [weak self] change in self?.handle(change) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func handle(_ change: StoreChange) {
        switch change {
        case .snapshot:
            toolbar.updateExtensions()
            let switched = store.snapshot.activeSpace != shownSpace
            shownSpace = store.snapshot.activeSpace
            let favoritesChanged = favorites.update(crossfade: switched)
            pager.update(animation: store.snapshotAnimation)
            bottom.update()
            address.update()
            updatePlayer()
            needsLayout = true
            if switched {
                Motion.instantly {
                    pager.layoutSubtreeIfNeeded()
                    favorites.layoutSubtreeIfNeeded()
                }
                Motion.animate(Motion.reflow) { layoutSubtreeIfNeeded() }
            } else if favoritesChanged {
                Motion.animate(Motion.reflow) { layoutSubtreeIfNeeded() }
            }
        case .nav:
            toolbar.update()
            address.update()
        case .extensions:
            toolbar.updateExtensions()
        case .blocked:
            address.update()
        case .media:
            updatePlayer()
            pager.refreshDecorations()
        case .update:
            refreshUpdateCard()
        case .cleanup:
            pager.refreshDecorations(animation: Motion.settle)
        case .renaming:
            pager.refreshDecorations()
        case .drag:
            favorites.update()
            pager.refreshDecorations()
            pager.dragChanged()
            needsLayout = true
            Motion.animate(Motion.quick) { layoutSubtreeIfNeeded() }
        default:
            break
        }
    }

    private func updatePlayer() {
        let media = store.mediaTab
        player.update(media)
        let visible = media != nil
        guard visible == player.isHidden else { return }
        player.isHidden = false
        player.alphaValue = visible ? 0 : 1
        Motion.animate(Motion.settle) {
            player.animator().alphaValue = visible ? 1 : 0
            needsLayout = true
            layoutSubtreeIfNeeded()
        } completion: { [weak self] in
            guard let self else { return }
            player.isHidden = store.mediaTab == nil
            needsLayout = true
        }
    }

    private static var readyUpdate: String? {
        Updater.shared.cardHidden ? nil : Updater.shared.readyVersion
    }

    private func refreshUpdateCard() {
        let version = Self.readyUpdate
        if let version { updateCard.update(version: version) }
        let visible = version != nil
        guard visible == updateCard.isHidden else { return }
        updateCard.isHidden = false
        updateCard.alphaValue = visible ? 0 : 1
        Motion.animate(Motion.settle) {
            updateCard.animator().alphaValue = visible ? 1 : 0
            needsLayout = true
            layoutSubtreeIfNeeded()
        } completion: { [weak self] in
            guard let self else { return }
            updateCard.isHidden = Self.readyUpdate == nil
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 20
        var y: CGFloat = 6
        toolbar.frame = NSRect(x: 10, y: y, width: width, height: 30)
        y += 30 + 10
        address.frame = NSRect(x: 10, y: y, width: width, height: 34)
        y += 34 + 10
        let favoritesHeight = favorites.preferredHeight(width: width)
        favorites.frame = NSRect(x: 10, y: y, width: width, height: favoritesHeight)
        if favoritesHeight > 0 { y += favoritesHeight + 10 }
        let bottomY = bounds.height - 8 - 28
        bottom.frame = NSRect(x: 10, y: bottomY, width: width, height: 28)
        var listBottom = bottomY - 10
        if Self.readyUpdate != nil || !updateCard.isHidden {
            updateCard.frame = NSRect(x: 10, y: listBottom - 46, width: width, height: 46)
            listBottom -= 46 + 10
        }
        if store.mediaTab != nil || !player.isHidden {
            player.frame = NSRect(x: 10, y: listBottom - 46, width: width, height: 46)
            listBottom -= 46 + 10
        }
        pager.frame = NSRect(x: 10, y: y, width: width, height: max(listBottom - y, 0))
    }
}

private final class SidebarToolbarView: WindowDragView {
    private let store: BrowserStore
    private let toggle: SymbolButton
    private let back: SymbolButton
    private let forward: SymbolButton
    private let reload: SymbolButton
    private let extensions: ExtensionButtonsView

    init(store: BrowserStore) {
        self.store = store
        extensions = ExtensionButtonsView(store: store)
        store.extensionButtons = extensions
        toggle = SymbolButton("sidebar.left") { store.toggleSidebar() }
        back = SymbolButton("arrow.left") { store.goBack() }
        forward = SymbolButton("arrow.right") { store.goForward() }
        reload = SymbolButton("arrow.clockwise") { store.reloadOrStop() }
        super.init(frame: .zero)
        back.menuSource = { [weak store] show in store?.navigationMenu(back: true, show) }
        forward.menuSource = { [weak store] show in store?.navigationMenu(back: false, show) }
        toggle.toolTip = "Focus Mode  ⌘S"
        for view in [toggle, back, forward, reload, extensions] as [NSView] { addSubview(view) }
        update()
    }

    func updateExtensions() {
        extensions.update()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        back.isEnabled = store.nav.canGoBack
        forward.isEnabled = store.nav.canGoForward
        reload.setSymbol(store.nav.isLoading ? "xmark" : "arrow.clockwise")
        reload.isEnabled = store.visibleTabID != nil
    }

    override func layout() {
        super.layout()
        toggle.frame = NSRect(x: 66, y: 3, width: 28, height: 24)
        reload.frame = NSRect(x: bounds.width - 28, y: 3, width: 28, height: 24)
        forward.frame = NSRect(x: bounds.width - 58, y: 3, width: 28, height: 24)
        back.frame = NSRect(x: bounds.width - 88, y: 3, width: 28, height: 24)
        let left = toggle.frame.maxX + 4
        let width = min(extensions.preferredWidth, max(back.frame.minX - 2 - left, 0))
        extensions.frame = NSRect(x: back.frame.minX - 2 - width, y: 0, width: width, height: bounds.height)
    }
}

private final class AddressPillView: HoverView {
    private var shownTab: UInt64?
    private let store: BrowserStore
    private let fill = FillLayer()
    private lazy var lock = SiteSecurityBadge(store: store)
    private let host = Label.make()
    private let spinner = NSProgressIndicator()
    private let shield = NSImageView()
    private let blocked = Label.make(size: 11, weight: .medium)
    private var shownCount = 0

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        shield.image = .symbol("shield.lefthalf.filled", size: 10, weight: .regular)
        shield.contentTintColor = .labelColor
        shield.alphaValue = 0.5
        blocked.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        blocked.alphaValue = 0.5
        blocked.wantsLayer = true
        for view in [lock, host, spinner, shield, blocked] as [NSView] { addSubview(view) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let tab = store.visibleTab
        lock.update()
        host.stringValue = tab?.host ?? "Search or Enter URL…"
        host.alphaValue = tab == nil ? 0.5 : 0.85
        if store.nav.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let count = tab == nil ? 0 : store.visibleBlockedCount
        let sameTab = tab?.id == shownTab
        shownTab = tab?.id
        shield.setVisible(count > 0, animated: sameTab)
        blocked.setVisible(count > 0, animated: sameTab)
        if count != shownCount {
            if count > shownCount, !Motion.reduced, let layer = blocked.layer {
                let roll = CATransition()
                roll.type = .push
                roll.subtype = .fromTop
                roll.duration = Motion.quick.duration
                roll.timingFunction = Motion.quick.timing
                layer.add(roll, forKey: "roll")
            }
            shownCount = count
            blocked.stringValue = "\(count)"
            toolTip = count > 0 ? "\(count) ads and trackers blocked on this page" : nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        var x: CGFloat = 10
        if !lock.isHidden {
            lock.frame = NSRect(x: x - 4, y: bounds.midY - 9, width: 18, height: 18)
            x += 16
        }
        var trailing = bounds.width - 10
        if shownCount > 0 {
            let width = blocked.textWidth
            blocked.frame = NSRect(x: trailing - width, y: bounds.midY - 7, width: width, height: 14)
            shield.frame = NSRect(x: trailing - width - 14, y: bounds.midY - 6, width: 11, height: 12)
            trailing -= width + 20
        }
        if store.nav.isLoading {
            spinner.frame = NSRect(x: trailing - 12, y: bounds.midY - 6, width: 12, height: 12)
            trailing -= 18
        }
        host.frame = NSRect(x: x, y: bounds.midY - 8, width: max(trailing - x, 0), height: 16)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.controlHoverFill : Theme.controlFill, in: effectiveAppearance)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        store.commandBar = store.visibleTab == nil ? .newTab : .editCurrent
    }

    override func mouseDown(with event: NSEvent) {}
}

private final class FavoritesGridView: FlippedView {
    private let store: BrowserStore
    private var tiles: [FavoriteTileView] = []
    private let caret = CALayer()
    private let hint = DropHintCellView()
    private var dropIndex: Int?
    private let maxColumns = 4
    private let tileHeight: CGFloat = 46
    private let spacing: CGFloat = 8

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        caret.cornerRadius = 1.5
        caret.isHidden = true
        layer?.addSublayer(caret)
        hint.configure("Drop to add to Favorites", visible: true)
        addSubview(hint)
        registerForDraggedTypes([.sidebarItem, .URL])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var space: SpaceInfo { store.activeSpace }

    private var columns: Int { max(1, min(space.favorites.count, maxColumns)) }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let count = space.favorites.count
        if count == 0 { return store.isDragging ? 34 : 0 }
        let rowCount = (count + columns - 1) / columns
        return CGFloat(rowCount) * tileHeight + CGFloat(rowCount - 1) * spacing
    }

    private var shownTabs: [UInt64] = []

    @discardableResult
    func update(crossfade: Bool = false) -> Bool {
        let favorites = space.favorites
        let ids = favorites.map(\.id)
        if crossfade, ids != shownTabs, !Motion.reduced {
            let fade = CATransition()
            fade.type = .fade
            if ids.count < shownTabs.count {
                fade.duration = Motion.quick.duration * 0.7
            } else {
                fade.duration = Motion.reflow.duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            }
            layer?.add(fade, forKey: "favorites")
        }
        let changed = ids != shownTabs
        let fadeIn = changed && !crossfade && !shownTabs.isEmpty
        shownTabs = ids
        while tiles.count > favorites.count { tiles.removeLast().removeFromSuperview() }
        while tiles.count < favorites.count {
            let tile = FavoriteTileView(store: store)
            tiles.append(tile)
            addSubview(tile)
            Motion.instantly { tile.frame = tileFrame(tiles.count - 1) }
            if fadeIn {
                tile.isHidden = true
                tile.setVisible(true, animated: true, curve: Motion.reflow)
            }
        }
        for (tile, tab) in zip(tiles, favorites) { tile.configure(tab, space: space) }
        hint.setVisible(favorites.isEmpty && store.isDragging, animated: true)
        needsLayout = true
        return changed
    }

    private func tileFrame(_ index: Int) -> NSRect {
        let width = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let row = index / columns, column = index % columns
        return NSRect(x: CGFloat(column) * (width + spacing), y: CGFloat(row) * (tileHeight + spacing),
                      width: width, height: tileHeight)
    }

    override func layout() {
        super.layout()
        hint.frame = bounds
        for (i, tile) in tiles.enumerated() { tile.frame = tileFrame(i) }
    }

    private func insertionIndex(at point: NSPoint) -> Int {
        guard !tiles.isEmpty else { return 0 }
        for (i, tile) in tiles.enumerated() where point.y <= tile.frame.maxY + spacing / 2 {
            if point.x < tile.frame.midX { return i }
            if i % columns == columns - 1 || i == tiles.count - 1 { return i + 1 }
        }
        return tiles.count
    }

    private func showCaret(at index: Int?) {
        guard index != dropIndex else { return }
        let wasShown = dropIndex != nil
        dropIndex = index
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.quick.duration)
        CATransaction.setAnimationTimingFunction(Motion.quick.timing)
        defer { CATransaction.commit() }
        guard let index, !tiles.isEmpty else {
            caret.opacity = 0
            return
        }
        let anchor = index < tiles.count ? tiles[index].frame : tiles[index - 1].frame
        let x = index < tiles.count ? anchor.minX - spacing / 2 : anchor.maxX + spacing / 2
        caret.backgroundColor = NSColor.controlAccentColor.cgColor
        let frame = NSRect(x: x - 1.5, y: anchor.minY + 6, width: 3, height: anchor.height - 12)
        if wasShown {
            caret.frame = frame
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caret.frame = frame
            caret.isHidden = false
            CATransaction.commit()
        }
        caret.opacity = 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        showCaret(at: insertionIndex(at: convert(sender.draggingLocation, from: nil)))
        return sender.draggingPasteboard.string(forType: .sidebarItem) != nil ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showCaret(at: nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        showCaret(at: nil)
        let target = DropTarget.favorites(profileId: space.profileId)
        if let id = sender.draggingPasteboard.string(forType: .sidebarItem).flatMap(UInt64.init) {
            guard store.core.tab(id: id) != nil else { return false }
            store.drop(id, on: target, index: index)
            return true
        }
        guard let url = sender.draggingPasteboard.string(forType: .URL) else { return false }
        store.dropURL(url, on: target, index: index)
        return true
    }
}

private final class FavoriteTileView: HoverView, NSDraggingSource {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let brand = FillLayer()
    private let icon = NSImageView()
    private var tab: TabInfo?
    private var space: SpaceInfo?
    private var downEvent: NSEvent?
    private var dragging = false

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 10
        brand.cornerRadius = 10
        layer?.addSublayer(fill)
        layer?.addSublayer(brand)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3.6
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: TabInfo, space: SpaceInfo) {
        self.tab = tab
        self.space = space
        icon.image = FaviconCache.shared.image(for: tab)
        icon.alphaValue = tab.live || space.activeTab == tab.id ? 1 : 0.6
        toolTip = tab.displayTitle
        needsDisplay = true
        updateLayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        brand.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
    }

    override func updateLayer() {
        guard let tab, let space else { return }
        let active = space.activeTab == tab.id
        fill.paint(fill: active ? Theme.selectedFill : hovering ? Theme.controlHoverFill : Theme.controlFill,
                   shadow: active ? Theme.selectedShadow : nil, in: effectiveAppearance)
        let color = active ? tab.faviconPath.flatMap { FaviconCache.shared.brandColor(atPath: $0) } : nil
        let dark = effectiveAppearance.isDark
        brand.paint(fill: color.map { $0.nsColor.withAlphaComponent(dark ? 0.32 : 0.2) },
                    border: color.map { $0.nsColor.withAlphaComponent(dark ? 0.6 : 0.45) }, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let downEvent, let tab else { return }
        let start = downEvent.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        dragging = true
        let item = NSPasteboardItem()
        item.setString(String(tab.id), forType: .sidebarItem)
        item.setString(tab.url, forType: .URL)
        item.setString(tab.url, forType: .string)
        let image = DragImages.pill(for: tab)
        let point = convert(event.locationInWindow, from: nil)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        store.beginDrag(tab.id)
        let session = beginDraggingSession(with: [dragItem], event: downEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragging, let tab, let space, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        store.select(tab.id, in: space.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab, let space else { return nil }
        return Menus.tab(tab, in: space, store: store)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        store.dragMoved(to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.endDrag(at: screenPoint, accepted: !operation.isEmpty)
    }
}

private final class SpacePagerView: FlippedView {
    private let store: BrowserStore
    private var pages: [UInt64: SpacePageView] = [:]
    private let gap: CGFloat = 24

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        store.pager.view = self
        store.pager.observe(self) { [weak self] in self?.positionChanged() }
        update(animation: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var stride: CGFloat { bounds.width + gap }

    func update(animation: Motion.Curve?) {
        let spaces = store.snapshot.spaces
        for (id, page) in pages where !spaces.contains(where: { $0.id == id }) {
            page.removeFromSuperview()
            pages[id] = nil
        }
        for space in spaces {
            pages[space.id]?.update(space, animation: animation)
        }
        ensurePages()
        layoutPages()
        preparePages()
    }

    func refreshDecorations(animation: Motion.Curve? = nil) {
        for page in pages.values { page.refreshDecorations(animation: animation) }
    }

    private let keepAll = 16

    private func wanted(_ index: Int) -> Bool {
        let span = store.pager.travel ?? store.pager.position...store.pager.position
        return CGFloat(index) > span.lowerBound - 1.2 && CGFloat(index) < span.upperBound + 1.2
    }

    private func makePage(_ space: SpaceInfo) {
        let page = SpacePageView(space: space, store: store)
        pages[space.id] = page
        addSubview(page)
        if let index = store.snapshot.spaces.firstIndex(where: { $0.id == space.id }) {
            Motion.instantly {
                page.frame = NSRect(x: (CGFloat(index) - store.pager.position) * stride, y: 0,
                                    width: bounds.width, height: bounds.height)
            }
        }
    }

    private var preparing = false

    private func preparePages() {
        guard !preparing, window != nil, store.snapshot.spaces.count <= keepAll,
              store.snapshot.spaces.contains(where: { pages[$0.id] == nil })
        else { return }
        preparing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            preparing = false
            guard store.pager.travel == nil, !store.pager.isTracking else { return preparePages() }
            guard let space = store.snapshot.spaces.first(where: { self.pages[$0.id] == nil }) else { return }
            makePage(space)
            preparePages()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        preparePages()
    }

    private func ensurePages() {
        for (index, space) in store.snapshot.spaces.enumerated() {
            if wanted(index) {
                if pages[space.id] == nil { makePage(space) }
            } else if store.snapshot.spaces.count > keepAll, !store.isDragging, let page = pages.removeValue(forKey: space.id) {
                page.removeFromSuperview()
            }
        }
    }

    func dragChanged() {
        if !store.isDragging { ensurePages() }
    }

    private func layoutPages() {
        let position = store.pager.position
        Motion.instantly {
            for (index, space) in store.snapshot.spaces.enumerated() {
                pages[space.id]?.frame = NSRect(x: (CGFloat(index) - position) * stride, y: 0,
                                                width: bounds.width, height: bounds.height)
            }
        }
    }

    private func positionChanged() {
        ensurePages()
        layoutPages()
    }

    override func layout() {
        super.layout()
        store.pager.pageWidth = stride
        layoutPages()
    }
}

private final class SidebarBottomBar: FlippedView {
    private let store: BrowserStore
    private let downloads = DownloadsButton()
    private let add: SymbolButton
    private var dots: [SpaceDotView] = []

    init(store: BrowserStore) {
        self.store = store
        add = SymbolButton("plus")
        super.init(frame: .zero)
        add.action = { [weak add] in
            guard let add else { return }
            Menus.newItem(store: store).popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add)
        }
        addSubview(downloads)
        addSubview(add)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let spaces = store.snapshot.spaces
        let shown = spaces.count > 1 ? spaces : []
        let changed = dots.count != shown.count
        let animated = changed && window != nil && !Motion.reduced
        while dots.count > shown.count { dots.removeLast().removeFromSuperview() }
        while dots.count < shown.count {
            let dot = SpaceDotView(store: store)
            dots.append(dot)
            addSubview(dot)
            if animated {
                dot.isHidden = true
                needsLayout = true
                Motion.instantly { layoutSubtreeIfNeeded() }
                dot.setVisible(true, animated: true, curve: Motion.reflow)
            }
        }
        for (dot, space) in zip(dots, shown) { dot.configure(space, active: space.id == store.snapshot.activeSpace) }
        needsLayout = true
        if animated { Motion.animate(Motion.reflow) { layoutSubtreeIfNeeded() } }
    }

    override func layout() {
        super.layout()
        downloads.frame = NSRect(x: 0, y: 2, width: 28, height: 24)
        add.frame = NSRect(x: bounds.width - 28, y: 2, width: 28, height: 24)
        guard !dots.isEmpty else { return }
        let available = bounds.width - 2 * 34
        let pitch = min(30, available / CGFloat(dots.count))
        var x = (bounds.width - pitch * CGFloat(dots.count)) / 2
        for dot in dots {
            dot.showsIcon = pitch >= 20
            dot.frame = NSRect(x: x, y: 0, width: pitch, height: bounds.height)
            x += pitch
        }
    }
}

private final class SpaceDotView: HoverView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let colorIcon = FillLayer()
    private let grayIcon = FillLayer()
    private let dot = FillLayer()
    private var space: SpaceInfo?
    private var iconText = ""
    private var active = false
    private var dropping = false
    private var pressed = false
    private var springLoad: Timer?
    private var warmTimer: Timer?
    var showsIcon = true {
        didSet { if showsIcon != oldValue { needsLayout = true } }
    }

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 7
        layer?.addSublayer(fill)
        for icon in [grayIcon, colorIcon] {
            icon.contentsGravity = .resizeAspect
            layer?.addSublayer(icon)
        }
        dot.cornerRadius = 2.5
        layer?.addSublayer(dot)
        registerForDraggedTypes([.sidebarItem, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ space: SpaceInfo, active: Bool) {
        self.space = space
        toolTip = space.name
        if space.icon != iconText {
            iconText = space.icon
            renderIcon()
        }
        guard active != self.active else { return }
        self.active = active
        hoverChanged()
    }

    override func hoverChanged() {
        super.hoverChanged()
        if hovering, !active, warmTimer == nil, let id = space?.id {
            let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.warmSpace(id) }
            }
            RunLoop.main.add(timer, forMode: .common)
            warmTimer = timer
        } else if !hovering {
            warmTimer?.invalidate()
            warmTimer = nil
        }
    }

    private func renderIcon() {
        let images = SpaceIconImages.images(for: iconText, scale: window?.backingScaleFactor ?? 2,
                                            appearance: effectiveAppearance)
        colorIcon.contents = images?.color
        grayIcon.contents = images?.gray
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderIcon()
    }

    override func layout() {
        super.layout()
        let icon = showsIcon && colorIcon.contents != nil
        let side = min(26, bounds.width - 2, bounds.height - 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        for layer in [colorIcon, grayIcon] {
            layer.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.isHidden = !icon
        }
        dot.bounds = NSRect(x: 0, y: 0, width: 5, height: 5)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.isHidden = icon
        CATransaction.commit()
        updateLayer()
    }

    override func updateLayer() {
        let lit = active || hovering || dropping
        fill.paint(fill: dropping ? Theme.controlHoverFill : hovering ? Theme.hoverFill : nil, in: effectiveAppearance)
        colorIcon.opacity = lit ? 1 : 0
        grayIcon.opacity = lit ? 0 : 0.6
        let scale = pressed ? CATransform3DMakeScale(0.84, 0.84, 1) : CATransform3DIdentity
        for layer in [colorIcon, grayIcon, dot] { layer.transform = scale }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.labelColor.withAlphaComponent(active ? 0.85 : hovering ? 0.6 : 0.3).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        hoverChanged()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        hoverChanged()
        if let space, bounds.contains(convert(event.locationInWindow, from: nil)) { store.activateSpace(space.id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let space else { return nil }
        let menu = NSMenu()
        menu.add("Edit Space…") { [store] in store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
        return menu
    }

    private func setDropping(_ value: Bool) {
        dropping = value
        hoverChanged()
        springLoad?.invalidate()
        springLoad = nil
        guard value, !active, let id = space?.id else { return }
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.activateSpace(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        springLoad = timer
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setDropping(true)
        return sender.draggingPasteboard.string(forType: .sidebarItem) != nil ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropping(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropping(false)
        guard let space else { return false }
        let target = DropTarget.today(spaceId: space.id)
        if let id = sender.draggingPasteboard.string(forType: .sidebarItem).flatMap(UInt64.init) {
            guard store.core.tab(id: id) != nil else { return false }
            store.drop(id, on: target, index: 0)
            return true
        }
        guard let url = sender.draggingPasteboard.string(forType: .URL) else { return false }
        store.dropURL(url, on: target, index: 0)
        return true
    }
}

@MainActor
private enum SpaceIconImages {
    private static var cache: [String: (color: CGImage, gray: CGImage)] = [:]
    private static let context = CIContext()

    static func images(for text: String, scale: CGFloat, appearance: NSAppearance) -> (color: CGImage, gray: CGImage)? {
        guard !text.isEmpty else { return nil }
        let key = "\(text) \(scale) \(appearance.isDark)"
        if let cached = cache[key] { return cached }
        let side = Int(16 * scale)
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: NSColor.labelColor,
            ])
            let size = string.size()
            string.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let color = bitmap.makeImage() else { return nil }
        let mono = CIImage(cgImage: color).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let gray = context.createCGImage(mono, from: CGRect(x: 0, y: 0, width: side, height: side)) else { return nil }
        cache[key] = (color, gray)
        return (color, gray)
    }
}
