import AppKit

let sidebarRowHeight: CGFloat = 30

struct TabRowData: Equatable {
    let tab: TabInfo
    let active: Bool
    let depth: Int
    let pinned: Bool
    let inLittleWindow: Bool
    let mediaPaused: Bool
}

enum SidebarRow: Equatable {
    case pinnedTab(TabRowData, PinnedRow)
    case folder(PinnedRow, renaming: Bool)
    case pinZone(expanded: Bool)
    case divider(hasToday: Bool)
    case cleanup(Int)
    case newTab
    case todayTab(TabRowData, index: Int)

    var id: String {
        switch self {
        case .pinnedTab(let data, _): "tab-\(data.tab.id)"
        case .folder(let row, _): "folder-\(row.id)"
        case .pinZone: "pin-zone"
        case .divider: "divider"
        case .cleanup: "cleanup"
        case .newTab: "new-tab"
        case .todayTab(let data, _): "tab-\(data.tab.id)"
        }
    }

    var height: CGFloat {
        switch self {
        case .pinZone(let expanded): expanded ? sidebarRowHeight : 4
        case .divider: 22
        case .cleanup: 96
        default: sidebarRowHeight
        }
    }

    var hasPill: Bool {
        switch self {
        case .pinnedTab, .folder, .newTab, .todayTab: true
        default: false
        }
    }

    var tabData: TabRowData? {
        switch self {
        case .pinnedTab(let data, _), .todayTab(let data, _): data
        default: nil
        }
    }
}

@MainActor
final class SpacePageView: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let store: BrowserStore
    private(set) var space: SpaceInfo
    private let header: SpaceHeaderView
    private let scroll = NSScrollView()
    private let table = SidebarTableView()
    private var rows: [SidebarRow] = []
    private var lastDropSpot: (Int, NSTableView.DropOperation)?

    init(space: SpaceInfo, store: BrowserStore) {
        self.store = store
        self.space = space
        header = SpaceHeaderView(space: space, store: store)
        super.init(frame: .zero)
        addSubview(header)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.registerForDraggedTypes([.sidebarItem, .URL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.store = store
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        addSubview(scroll)
        rows = makeRows()
        table.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 24)
        scroll.frame = NSRect(x: 0, y: 30, width: bounds.width, height: max(bounds.height - 30, 0))
        table.tableColumns.first?.width = bounds.width
    }

    func update(_ space: SpaceInfo, animation: Motion.Curve?) {
        self.space = space
        header.update(space)
        let next = makeRows()
        let old = rows
        guard next != old else { return }
        let oldIDs = old.map(\.id), nextIDs = next.map(\.id)
        if oldIDs == nextIDs {
            var changed = IndexSet()
            var heightChanged = IndexSet()
            for i in next.indices where next[i] != old[i] {
                changed.insert(i)
                if next[i].height != old[i].height { heightChanged.insert(i) }
            }
            rows = next
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            for i in changed { (table.rowView(atRow: i, makeIfNecessary: false) as? SidebarRowView)?.configure(rows[i]) }
            if !heightChanged.isEmpty {
                Motion.animate(animation ?? Motion.quick) { table.noteHeightOfRows(withIndexesChanged: heightChanged) }
            }
            return
        }
        let diff = nextIDs.difference(from: oldIDs)
        var removed = IndexSet(), inserted = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard removed.count + inserted.count <= max(8, next.count / 2) else {
            rows = next
            table.reloadData()
            return
        }
        let pagerMoving = store.pager.travel != nil || store.pager.isTracking
        let curve = animation ?? (removed.count + inserted.count <= 6 && !pagerMoving ? Motion.quick : nil)
        let animated = curve != nil && !Motion.reduced && window != nil
        let moved: (from: Int, to: Int)? = {
            guard removed.count == 1, inserted.count == 1, let from = removed.first, let to = inserted.first,
                  oldIDs[from] == nextIDs[to] else { return nil }
            return (from, to)
        }()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? curve!.duration : 0
            context.timingFunction = curve?.timing
            table.beginUpdates()
            if let moved {
                table.moveRow(at: moved.from, to: moved.to)
            } else {
                table.removeRows(at: removed, withAnimation: animated ? [.effectFade, .slideUp] : [])
                table.insertRows(at: inserted, withAnimation: animated ? [.effectFade, .slideDown] : [])
            }
            rows = next
            table.endUpdates()
        }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = IndexSet(next.indices.filter {
            (moved != nil || !inserted.contains($0)) && before[next[$0].id] != next[$0]
        })
        table.reloadData(forRowIndexes: changed, columnIndexes: [0])
        for i in changed { (table.rowView(atRow: i, makeIfNecessary: false) as? SidebarRowView)?.configure(rows[i]) }
    }

    func refreshDecorations(animation: Motion.Curve? = nil) {
        update(space, animation: animation)
    }

    private func makeRows() -> [SidebarRow] {
        var out: [SidebarRow] = []
        func data(_ tab: TabInfo, depth: Int, pinned: Bool) -> TabRowData {
            TabRowData(tab: tab, active: space.activeTab == tab.id, depth: depth, pinned: pinned,
                       inLittleWindow: store.isInLittleWindow(tab.id), mediaPaused: store.pausedMediaTab == tab.id)
        }
        for row in space.pinned {
            if let tab = row.tab {
                out.append(.pinnedTab(data(tab, depth: Int(row.depth), pinned: true), row))
            } else {
                out.append(.folder(row, renaming: store.renamingFolder == row.id))
            }
        }
        if space.pinned.isEmpty { out.append(.pinZone(expanded: store.isDragging)) }
        out.append(.divider(hasToday: !space.today.isEmpty))
        if space.id == store.activeSpace.id, let count = store.cleanupOffer { out.append(.cleanup(count)) }
        out.append(.newTab)
        for (index, tab) in space.today.enumerated() {
            out.append(.todayTab(data(tab, depth: 0, pinned: false), index: index))
        }
        return out
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView
            ?? SidebarRowView()
        view.identifier = SidebarRowView.identifier
        view.configure(rows[row])
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .pinnedTab(let data, _), .todayTab(let data, _):
            let cell = reuse(TabCellView.self) { TabCellView(store: store) }
            cell.configure(data, space: space)
            return cell
        case .folder(let folder, let renaming):
            let cell = reuse(FolderCellView.self) { FolderCellView(store: store) }
            cell.configure(folder, renaming: renaming)
            return cell
        case .pinZone(let expanded):
            let cell = reuse(DropHintCellView.self) { DropHintCellView() }
            cell.configure("Drop here to pin", visible: expanded)
            return cell
        case .divider(let hasToday):
            let cell = reuse(DividerCellView.self) { DividerCellView() }
            cell.configure(showsClear: hasToday) { [weak self] in
                guard let self else { return }
                store.clearToday(space.id)
            }
            return cell
        case .cleanup(let count):
            let cell = reuse(CleanupCellView.self) { CleanupCellView(store: store) }
            cell.configure(count: count)
            return cell
        case .newTab:
            return reuse(NewTabCellView.self) { NewTabCellView() }
        }
    }

    private func reuse<T: NSView>(_ type: T.Type, make: () -> T) -> T {
        let id = NSUserInterfaceItemIdentifier(String(describing: type))
        if let view = table.makeView(withIdentifier: id, owner: nil) as? T { return view }
        let view = make()
        view.identifier = id
        return view
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .pinnedTab(let data, _), .todayTab(let data, _):
            store.select(data.tab.id, in: space.id)
        case .folder(let folder, let renaming):
            if !renaming { store.setFolder(folder.id, expanded: !folder.expanded) }
        case .newTab:
            store.activateSpace(space.id)
            store.commandBar = .newTab
        default:
            break
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        let built: NSMenu? = switch rows[row] {
        case .pinnedTab(let data, _), .todayTab(let data, _): Menus.tab(data.tab, in: space, store: store)
        case .folder(let folder, _): Menus.folder(folder, in: space, store: store)
        default: nil
        }
        for item in built?.items ?? [] {
            built?.removeItem(item)
            menu.addItem(item)
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        switch rows[row] {
        case .pinnedTab(let data, _), .todayTab(let data, _):
            item.setString(String(data.tab.id), forType: .sidebarItem)
            item.setString(data.tab.url, forType: .URL)
            item.setString(data.tab.url, forType: .string)
        case .folder(let folder, _):
            item.setString(String(folder.id), forType: .sidebarItem)
        default:
            return nil
        }
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first else { return }
        let id: UInt64
        let preview: NSImage
        switch rows[row] {
        case .pinnedTab(let data, _), .todayTab(let data, _):
            id = data.tab.id
            preview = DragImages.pill(for: data.tab)
        case .folder(let folder, _):
            id = folder.id
            preview = DragImages.pill(title: folder.folderName ?? "Folder", icon: .symbol("folder.fill", size: 12))
        default:
            return
        }
        store.beginDrag(id)
        table.dragPreview = preview
        table.windowPreview = rows[row].tabData.map { DragImages.window(for: $0.tab) }
        session.animatesToStartingPositionsOnCancelOrFail = true
        table.centerDragImage(session, image: preview, at: screenPoint)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.endDrag(at: screenPoint, accepted: !operation.isEmpty)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        var operation = operation
        let intoFolder = operation == .on && rows.indices.contains(row) && {
            if case .folder = rows[row] { true } else { false }
        }()
        if operation == .on && !intoFolder {
            operation = .above
            tableView.setDropRow(row, dropOperation: .above)
        }
        guard let (target, _) = dropTarget(row: row, operation: operation) else { return [] }
        let dragged = draggedItemID(info)
        if let dragged, store.core.tab(id: dragged) == nil {
            guard case .pinned = target else { return [] }
        }
        if lastDropSpot.map({ $0 != (row, operation) }) ?? true {
            lastDropSpot = (row, operation)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        return dragged != nil ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        lastDropSpot = nil
        guard let (target, index) = dropTarget(row: row, operation: dropOperation) else { return false }
        if let id = draggedItemID(info) {
            store.drop(id, on: target, index: index)
            return true
        }
        guard let url = info.draggingPasteboard.string(forType: .URL) ?? info.draggingPasteboard.string(forType: .string)
        else { return false }
        store.dropURL(url, on: target, index: index)
        return true
    }

    private func draggedItemID(_ info: NSDraggingInfo) -> UInt64? {
        info.draggingPasteboard.string(forType: .sidebarItem).flatMap(UInt64.init)
    }

    private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> (DropTarget, Int)? {
        if operation == .on, rows.indices.contains(row), case .folder(let folder, _) = rows[row] {
            return (.pinned(spaceId: space.id, folderId: folder.id), Int(UInt32.max))
        }
        guard row < rows.count else { return (.today(spaceId: space.id), space.today.count) }
        switch rows[max(row, 0)] {
        case .pinnedTab(_, let pinned), .folder(let pinned, _):
            return (.pinned(spaceId: space.id, folderId: pinned.parentId), Int(pinned.index))
        case .pinZone:
            return (.pinned(spaceId: space.id, folderId: nil), 0)
        case .divider:
            return (.pinned(spaceId: space.id, folderId: nil), Int(UInt32.max))
        case .cleanup, .newTab:
            return (.today(spaceId: space.id), 0)
        case .todayTab(_, let index):
            return (.today(spaceId: space.id), index)
        }
    }
}

final class SidebarTableView: NSTableView {
    weak var store: BrowserStore?
    var dragPreview: NSImage?
    var windowPreview: NSImage?
    private var showingWindow = false

    override static var isCompatibleWithResponsiveScrolling: Bool { false }

    override var visibleRect: NSRect {
        guard let clip = enclosingScrollView?.contentView, window != nil else { return super.visibleRect }
        return clip.documentVisibleRect.intersection(bounds)
    }

    func centerDragImage(_ session: NSDraggingSession, image: NSImage, at screenPoint: NSPoint) {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        session.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                       searchOptions: [:]) { item, _, _ in
            let size = image.size
            item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                         width: size.width, height: size.height), contents: image)
        }
        showingWindow = false
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        if NSTableView.instancesRespond(to: #selector(NSDraggingSource.draggingSession(_:movedTo:))) {
            super.draggingSession(session, movedTo: screenPoint)
        }
        guard let store else { return }
        store.dragMoved(to: screenPoint)
        let overPage = store.dragOverPage != nil
        guard overPage != showingWindow, let image = overPage ? windowPreview : dragPreview else { return }
        showingWindow = overPage
        centerDragImage(session, image: image, at: screenPoint)
        showingWindow = overPage
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is NSButton || responder is NSTextField ? true : super.validateProposedFirstResponder(responder, for: event)
    }
}

final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
    private let fill = FillLayer()
    private var hovering = false
    private var area: NSTrackingArea?
    private var row: SidebarRow = .newTab

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ row: SidebarRow) {
        self.row = row
        needsDisplay = true
        updateLayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
        setHovering(isUnderPointer)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? HoverAware)?.setHovering(hovering)
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        FillLayer.animated(Motion.quick) { updateLayer() }
        (subviews.first as? HoverAware)?.setHovering(value)
    }

    override func updateLayer() {
        let active = row.tabData?.active == true
        fill.paint(fill: !row.hasPill ? nil : active ? Theme.selectedFill : hovering ? Theme.hoverFill : nil,
                   shadow: active ? Theme.selectedShadow : nil, in: effectiveAppearance)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

@MainActor
protocol HoverAware: AnyObject {
    func setHovering(_ hovering: Bool)
}

final class TabCellView: NSTableCellView, HoverAware {
    private let store: BrowserStore
    private let favicon = NSImageView()
    private let title = Label.make()
    private let close = NSButton()
    private let badge = NSImageView()
    private let equalizer = EqualizerView()
    private var data: TabRowData?
    private var hovering = false

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.wantsLayer = true
        favicon.layer?.cornerRadius = 3.2
        favicon.layer?.cornerCurve = .continuous
        favicon.layer?.masksToBounds = true
        favicon.contentTintColor = .secondaryLabelColor
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.wantsLayer = true
        close.layer?.cornerRadius = 5
        close.layer?.cornerCurve = .continuous
        close.onAction { [weak self] in
            guard let self, let data else { return }
            self.store.closeAsking(data.tab.id)
        }
        badge.image = .symbol("macwindow", size: 10, weight: .regular)
        badge.contentTintColor = .labelColor
        badge.alphaValue = 0.5
        badge.toolTip = "Open in a little window"
        equalizer.onClick = { [weak self] in if let self, let data { store.toggleMute(data.tab.id) } }
        for view in [favicon, title, close, badge, equalizer] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ data: TabRowData, space: SpaceInfo) {
        self.data = data
        let tab = data.tab
        favicon.image = FaviconCache.shared.image(for: tab)
        title.stringValue = tab.displayTitle
        title.font = Theme.font(13, data.active ? .medium : .regular)
        title.alphaValue = data.active ? 1 : 0.85
        let dim: CGFloat = tab.live || data.active ? 1 : 0.55
        favicon.alphaValue = dim
        title.alphaValue *= dim
        close.image = .symbol(data.pinned ? "minus" : "xmark", size: 9, weight: .bold)
        close.toolTip = data.pinned ? "Unload tab" : "Close tab"
        toolTip = hovering ? tab.displayTitle : nil
        updateAccessory()
        needsLayout = true
    }

    private var warmTimer: Timer?

    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        toolTip = hovering ? data?.tab.displayTitle : nil
        updateAccessory()
        warmTimer?.invalidate()
        warmTimer = nil
        guard hovering, let tab = data?.tab, !tab.live else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.warmTab(tab.id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        warmTimer = timer
    }

    private var accessoryTab: UInt64?

    private func updateAccessory() {
        guard let data else { return }
        let animated = accessoryTab == data.tab.id
        accessoryTab = data.tab.id
        let showClose = hovering && (!data.pinned || data.tab.live)
        close.setVisible(showClose, animated: animated)
        badge.setVisible(!showClose && data.inLittleWindow, animated: animated)
        let audible = !showClose && !data.inLittleWindow && data.tab.audible
        equalizer.setVisible(audible, animated: animated)
        equalizer.playing = audible && !data.mediaPaused && !data.tab.muted
        equalizer.showMuted(data.tab.muted)
        needsLayout = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            close.layer?.backgroundColor = Theme.faint(0.08).cgColor
        }
    }

    override func layout() {
        super.layout()
        let leading = 10 + CGFloat(data?.depth ?? 0) * 14
        let midY = bounds.midY
        favicon.frame = NSRect(x: leading, y: midY - 8, width: 16, height: 16)
        close.frame = NSRect(x: bounds.width - 26, y: midY - 10, width: 20, height: 20)
        badge.frame = NSRect(x: bounds.width - 24, y: midY - 7, width: 16, height: 14)
        equalizer.frame = NSRect(x: bounds.width - 22, y: midY - 5.5, width: 12, height: 11)
        let titleX = leading + 24
        let showsAccessory = data.map { d in
            (hovering && (!d.pinned || d.tab.live)) || d.inLittleWindow || d.tab.audible
        } ?? false
        let trailing = showsAccessory ? 30.0 : 8.0
        title.frame = NSRect(x: titleX, y: midY - 8, width: max(bounds.width - titleX - trailing, 0), height: 16)
    }
}

final class FolderCellView: NSTableCellView, NSTextFieldDelegate {
    private let store: BrowserStore
    private let chevron = CALayer()
    private let icon = NSImageView()
    private let name = Label.make()
    private let editor = NSTextField()
    private let count = Label.chip()
    private var row: PinnedRow?
    private var expanded = false

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        chevron.contentsGravity = .center
        chevron.opacity = 0.45
        layer?.addSublayer(chevron)
        icon.contentTintColor = .labelColor
        icon.alphaValue = 0.7
        name.alphaValue = 0.8
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = Theme.font(13)
        editor.placeholderString = "Folder name"
        editor.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        count.textColor = .labelColor
        count.alphaValue = 0.6
        count.layer?.cornerRadius = 8.5
        for view in [icon, name, editor, count] as [NSView] { addSubview(view) }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let image = NSImage.symbol("chevron.right", size: 9, weight: .bold)?
            .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
        chevron.contents = image
        chevron.contentsScale = window?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: PinnedRow, renaming: Bool) {
        let wasRenaming = !editor.isHidden && self.row?.id == row.id
        let sameFolder = self.row?.id == row.id
        self.row = row
        icon.image = .symbol(row.expanded ? "folder" : "folder.fill", size: 12, weight: .regular)
        name.stringValue = row.folderName ?? "Folder"
        name.isHidden = renaming
        editor.isHidden = !renaming
        if renaming && !wasRenaming {
            editor.stringValue = row.folderName ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window?.makeFirstResponder(editor)
                editor.currentEditor()?.selectAll(nil)
            }
        }
        let collapsedCount = !row.expanded && row.childCount > 0
        count.setVisible(collapsedCount, animated: sameFolder)
        count.stringValue = "\(row.childCount)"
        effectiveAppearance.performAsCurrentDrawingAppearance {
            count.layer?.backgroundColor = Theme.faint(0.08).cgColor
        }
        let turn = row.expanded ? CATransform3DMakeRotation(-.pi / 2, 0, 0, 1) : CATransform3DIdentity
        CATransaction.begin()
        if expanded != row.expanded, !Motion.reduced, window != nil {
            CATransaction.setAnimationDuration(Motion.quick.duration)
            CATransaction.setAnimationTimingFunction(Motion.quick.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        chevron.transform = turn
        CATransaction.commit()
        expanded = row.expanded
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let leading = 8 + CGFloat(row?.depth ?? 0) * 14
        let midY = bounds.midY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        chevron.position = CGPoint(x: leading + 5, y: midY)
        CATransaction.commit()
        icon.frame = NSRect(x: leading + 16, y: midY - 7, width: 16, height: 14)
        let countWidth: CGFloat = count.isHidden ? 0 : max(24, count.textWidth + 12)
        count.frame = NSRect(x: bounds.width - 8 - countWidth, y: midY - 8.5, width: countWidth, height: 17)
        let textX = leading + 38
        let textWidth = max(bounds.width - textX - countWidth - 14, 0)
        name.frame = NSRect(x: textX, y: midY - 8, width: textWidth, height: 16)
        editor.frame = NSRect(x: textX - 2, y: midY - 9, width: textWidth + 4, height: 18)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let row else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            store.renamingFolder = nil
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            store.renameFolder(row.id, to: editor.stringValue)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let row, store.renamingFolder == row.id else { return }
        store.renameFolder(row.id, to: editor.stringValue)
    }
}

final class DividerCellView: NSTableCellView {
    private let line = CALayer()
    private let clear = NSButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        clear.isBordered = false
        clear.bezelStyle = .regularSquare
        clear.image = .symbol("arrow.down", size: 9.5)
        clear.imagePosition = .imageLeading
        clear.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: Theme.font(11, .medium), .foregroundColor: NSColor.labelColor,
        ])
        clear.contentTintColor = .labelColor
        clear.alphaValue = 0.55
        clear.toolTip = "Archive all Today tabs in this space"
        addSubview(clear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    private var showsClear = false
    private var lineAnimates = false

    func configure(showsClear: Bool, clearAction: @escaping () -> Void) {
        lineAnimates = showsClear != self.showsClear && window != nil && !Motion.reduced
        self.showsClear = showsClear
        clear.setVisible(showsClear, animated: lineAnimates)
        clear.onAction(clearAction)
        needsLayout = true
    }

    override func updateLayer() {
        line.backgroundColor = Theme.faint(0.12).cgColor
    }

    override func layout() {
        super.layout()
        let clearWidth = clear.intrinsicContentSize.width + 4
        clear.frame = NSRect(x: bounds.width - 6 - clearWidth, y: 0, width: clearWidth, height: bounds.height)
        CATransaction.begin()
        if lineAnimates {
            CATransaction.setAnimationDuration(Motion.quick.duration)
            CATransaction.setAnimationTimingFunction(Motion.quick.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        lineAnimates = false
        let room = showsClear ? clearWidth + 8 : 0
        line.frame = NSRect(x: 6, y: bounds.midY, width: max(bounds.width - 12 - room, 0), height: 1)
        CATransaction.commit()
    }
}

final class NewTabCellView: NSTableCellView {
    private let plus = NSImageView()
    private let title = Label.make("New Tab")

    init() {
        super.init(frame: .zero)
        plus.image = .symbol("plus", size: 12)
        plus.contentTintColor = .labelColor
        alphaValue = 0.6
        addSubview(plus)
        addSubview(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        plus.frame = NSRect(x: 10, y: bounds.midY - 7, width: 16, height: 14)
        title.frame = NSRect(x: 34, y: bounds.midY - 8, width: max(bounds.width - 40, 0), height: 16)
    }
}

final class DropHintCellView: NSTableCellView {
    private let label = Label.make(size: 11, weight: .medium)
    private let dash = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.alignment = .center
        label.alphaValue = 0.6
        addSubview(label)
        dash.fillColor = nil
        dash.lineDashPattern = [4, 3]
        dash.lineWidth = 1
        layer?.addSublayer(dash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ text: String, visible: Bool) {
        label.stringValue = text
        let animated = window != nil && !Motion.reduced
        label.setVisible(visible, animated: animated)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Motion.quick.duration)
        } else {
            CATransaction.setDisableActions(true)
        }
        dash.opacity = visible ? 1 : 0
        CATransaction.commit()
        needsLayout = true
    }

    override func updateLayer() {
        dash.strokeColor = Theme.faint(0.35).cgColor
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: bounds.midY - 7, width: bounds.width, height: 14)
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil)
    }
}

final class SpaceHeaderView: FlippedView {
    private let store: BrowserStore
    private var space: SpaceInfo
    private let icon = Label.make(size: 14)
    private let name = Label.make(size: 13, weight: .semibold)

    init(space: SpaceInfo, store: BrowserStore) {
        self.space = space
        self.store = store
        super.init(frame: .zero)
        name.alphaValue = 0.8
        for view in [icon, name] { addSubview(view) }
        update(space)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ space: SpaceInfo) {
        self.space = space
        icon.setIfChanged(space.icon.isEmpty ? "•" : space.icon)
        name.setIfChanged(space.name)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: 3, width: 20, height: 18)
        name.frame = NSRect(x: 28, y: 4, width: max(bounds.width - 34, 0), height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        Menus.space(space, store: store)
    }
}

@MainActor
enum DragImages {
    static func pill(for tab: TabInfo) -> NSImage {
        pill(title: tab.displayTitle, icon: FaviconCache.shared.image(for: tab))
    }

    static func pill(title: String, icon: NSImage?) -> NSImage {
        let size = NSSize(width: 220, height: 30)
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            Theme.cardFill.setFill()
            shape.fill()
            Theme.faint(0.12).setStroke()
            shape.stroke()
            icon?.draw(in: NSRect(x: 10, y: 7, width: 16, height: 16))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.font(13, .medium), .foregroundColor: NSColor.labelColor,
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            text.draw(with: NSRect(x: 34, y: 8, width: rect.width - 44, height: 16),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            return true
        }
    }

    static func window(for tab: TabInfo) -> NSImage {
        let size = NSSize(width: 200, height: 150)
        let icon = FaviconCache.shared.image(for: tab)
        return NSImage(size: size, flipped: true) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            Theme.toastFill.setFill()
            frame.fill()
            Theme.faint(0.15).setStroke()
            frame.stroke()
            for i in 0..<3 {
                Theme.faint(0.2).setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 12, y: 9, width: 7, height: 7)).fill()
            }
            let page = NSBezierPath(roundedRect: NSRect(x: 5, y: 26, width: rect.width - 10, height: rect.height - 31),
                                    xRadius: 8, yRadius: 8)
            NSColor.white.setFill()
            page.fill()
            icon.draw(in: NSRect(x: rect.midX - 14, y: rect.midY - 4, width: 28, height: 28))
            return true
        }
    }
}
