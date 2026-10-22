import AppKit

@MainActor
final class SidebarRail: FlippedView {
    static let width: CGFloat = 80

    private let store: BrowserStore
    private let toggle: SymbolButton
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let switcher: RailSpaceSwitcher
    private var tabs: [RailTabView] = []
    private var dividers: [CALayer] = []
    private let add: SymbolButton

    init(store: BrowserStore) {
        self.store = store
        toggle = SymbolButton("sidebar.left") { store.setLayout(.full) }
        add = SymbolButton("plus") { store.commandBar = .newTab }
        switcher = RailSpaceSwitcher(store: store)
        super.init(frame: .zero)
        toggle.toolTip = "Full Sidebar"
        add.toolTip = "New Tab  ⌘T"
        list.wantsLayer = true
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        for view in [toggle, scroll, switcher] as [NSView] { addSubview(view) }
        list.addSubview(add)
        store.observe(self) { [weak self] change in
            switch change {
            case .snapshot, .media: self?.update()
            default: break
            }
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var stale = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, stale { update() }
    }

    private func update() {
        guard window != nil else {
            stale = true
            return
        }
        stale = false
        let space = store.activeSpace
        let all = space.favorites + space.pinned.compactMap(\.tab) + space.today
        let reflow = tabs.count != all.count && !tabs.isEmpty && !Motion.reduced
        while tabs.count > all.count { tabs.removeLast().removeFromSuperview() }
        while tabs.count < all.count {
            let view = RailTabView(store: store)
            tabs.append(view)
            list.addSubview(view)
        }
        for (view, tab) in zip(tabs, all) { view.configure(tab, space: space) }
        switcher.update()
        needsLayout = true
        if reflow { Motion.animate(Motion.reflow) { layoutSubtreeIfNeeded() } }
    }

    override func layout() {
        super.layout()
        toggle.frame = NSRect(x: (bounds.width - 28) / 2, y: 36, width: 28, height: 24)
        switcher.frame = NSRect(x: (bounds.width - 40) / 2, y: bounds.height - 8 - 32, width: 40, height: 32)
        scroll.frame = NSRect(x: 0, y: 66, width: bounds.width, height: max(switcher.frame.minY - 72, 0))
        layoutList()
    }

    private func layoutList() {
        let space = store.activeSpace
        let favorites = space.favorites.count
        let pinned = space.pinned.compactMap(\.tab).count
        for divider in dividers { divider.removeFromSuperlayer() }
        dividers.removeAll()
        var y: CGFloat = 0
        var index = 0
        let x = (bounds.width - 40) / 2
        func place(_ count: Int) {
            for _ in 0..<count where index < tabs.count {
                tabs[index].frame = NSRect(x: x, y: y, width: 40, height: 32)
                y += 35
                index += 1
            }
        }
        func divider() {
            let line = CALayer()
            effectiveAppearance.performAsCurrentDrawingAppearance { line.backgroundColor = Theme.faint(0.12).cgColor }
            line.frame = NSRect(x: (bounds.width - 28) / 2, y: y + 4, width: 28, height: 1)
            list.layer?.addSublayer(line)
            dividers.append(line)
            y += 9
        }
        place(favorites)
        if favorites > 0, pinned > 0 { divider() }
        place(pinned)
        divider()
        add.frame = NSRect(x: (bounds.width - 28) / 2, y: y + 4, width: 28, height: 24)
        y += 35
        place(tabs.count - index)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: y + 8)
    }
}

private final class RailTabView: HoverView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let equalizer = EqualizerView()
    private var tab: TabInfo?
    private var space: SpaceInfo?

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        equalizer.alphaValue = 0.7
        addSubview(icon)
        addSubview(equalizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: TabInfo, space: SpaceInfo) {
        self.tab = tab
        self.space = space
        icon.image = FaviconCache.shared.image(for: tab)
        icon.alphaValue = tab.live || space.activeTab == tab.id ? 1 : 0.55
        equalizer.isHidden = !tab.audible
        equalizer.playing = tab.audible && store.pausedMediaTab != tab.id
        toolTip = tab.displayTitle
        needsDisplay = true
        updateLayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        equalizer.frame = NSRect(x: bounds.width - 12, y: bounds.height - 11, width: 9, height: 8)
    }

    override func updateLayer() {
        let active = tab.map { space?.activeTab == $0.id } ?? false
        fill.paint(fill: active ? Theme.selectedFill : hovering ? Theme.hoverFill : nil,
                   shadow: active ? Theme.selectedShadow : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let tab, let space, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        store.select(tab.id, in: space.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab, let space else { return nil }
        return Menus.tab(tab, in: space, store: store)
    }
}

private final class RailSpaceSwitcher: HoverView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let label = Label.make(size: 16)

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let space = store.activeSpace
        label.stringValue = space.icon.isEmpty ? "•" : space.icon
        toolTip = space.name
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        label.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.hoverFill : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for space in store.snapshot.spaces {
            menu.add("\(space.icon) \(space.name)", state: space.id == store.snapshot.activeSpace) { [store] in
                store.activateSpace(space.id)
            }
        }
        menu.addItem(.separator())
        menu.add("New Space…") { [store] in store.spaceEditor = SpaceEditorRequest(spaceID: nil) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
