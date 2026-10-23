import AppKit

enum InspectorPanelKind: String, CaseIterable {
    case elements, console, network, sources, application, performance

    var title: String {
        switch self {
        case .elements: "Elements"
        case .console: "Console"
        case .network: "Network"
        case .sources: "Sources"
        case .application: "Application"
        case .performance: "Performance"
        }
    }

    var symbol: String {
        switch self {
        case .elements: "chevron.left.forwardslash.chevron.right"
        case .console: "terminal"
        case .network: "arrow.up.arrow.down"
        case .sources: "doc.text"
        case .application: "externaldrive"
        case .performance: "gauge.with.dots.needle.67percent"
        }
    }

    @MainActor
    func makePanel() -> InspectorPanelView {
        switch self {
        case .elements: ElementsPanel()
        case .console: ConsolePanel()
        case .network: NetworkPanel()
        case .sources: SourcesPanel()
        case .application: ApplicationPanel()
        case .performance: PerformancePanel()
        }
    }
}

enum InspectorSettings {
    static let widthKey = "inspectorWidth"
    static let panelKey = "inspectorPanel"
    static let minWidth: CGFloat = 340

    static var width: CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: widthKey))
        return saved > 0 ? max(saved, minWidth) : 460
    }

    static var panel: InspectorPanelKind {
        UserDefaults.standard.string(forKey: panelKey).flatMap(InspectorPanelKind.init) ?? .elements
    }

    static let debugPanel = ProcessInfo.processInfo.environment["MBGA_DEBUG_INSPECTOR"].flatMap(InspectorPanelKind.init)
}

@MainActor
final class InspectorView: FlippedView {
    static let headerHeight: CGFloat = 40
    private let store: BrowserStore
    private let header: InspectorHeaderView
    private let card = InspectorCardView()
    private var panels: [InspectorPanelKind: InspectorPanelView] = [:]
    private var shownPanel: InspectorPanelKind?
    private let empty = InspectorEmptyView("Open a page to inspect it.")

    var cornerRadius: CGFloat = 8 {
        didSet { if cornerRadius != oldValue { card.cornerRadius = cornerRadius } }
    }

    func setTint(_ stops: [RGB], curve: Motion.Curve?) {
        guard stops != InspectorTheme.tint else { return }
        InspectorTheme.tint = stops
        card.updateSurface(curve: curve)
        NotificationCenter.default.post(name: InspectorTheme.tintChanged, object: nil)
    }

    init(store: BrowserStore) {
        self.store = store
        header = InspectorHeaderView(store: store)
        super.init(frame: .zero)
        addSubview(header)
        addSubview(card)
        card.content.addSubview(empty)
        store.observe(self) { [weak self] change in
            if case .inspector = change { self?.update() }
        }
        NotificationCenter.default.addObserver(forName: Self.debugRow, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.currentPanel?.selectRow(note.userInfo?["row"] as? Int ?? 0) }
        }
    }

    static let debugRow = Notification.Name("MBGAInspectorDebugRow")

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        card.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: max(bounds.height - Self.headerHeight - 8, 0))
        for panel in panels.values { panel.frame = card.content.bounds }
        empty.frame = card.content.bounds
    }

    func update() {
        header.update()
        guard store.inspectorOpen else {
            for panel in panels.values { panel.setShown(false) }
            return
        }
        let kind = store.inspectorPanel
        let session = store.inspectorSession
        let panel = panels[kind] ?? {
            let panel = kind.makePanel()
            panel.frame = card.content.bounds
            panel.autoresizingMask = [.width, .height]
            card.content.addSubview(panel)
            panels[kind] = panel
            return panel
        }()
        for (other, view) in panels where other != kind {
            view.isHidden = true
            view.setShown(false)
        }
        panel.isHidden = session == nil
        empty.isHidden = session != nil
        panel.bind(session)
        panel.setShown(session != nil)
        shownPanel = kind
    }

    var currentPanel: InspectorPanelView? { shownPanel.flatMap { panels[$0] } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "f":
            if let text = responder as? NSTextView, !text.isFieldEditor, text.usesFindBar {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performTextFinderAction(item)
            } else {
                currentPanel?.focusFilter()
            }
            return true
        case "[", "]":
            let all = InspectorPanelKind.allCases
            let index = all.firstIndex(of: store.inspectorPanel) ?? 0
            let step = event.charactersIgnoringModifiers == "]" ? 1 : -1
            store.showInspector(all[(index + step + all.count) % all.count])
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

final class InspectorCardView: NSView {
    let content = FlippedView()
    private let shadowLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.cornerCurve = .continuous
        shadowLayer.shadowRadius = 6
        shadowLayer.shadowOffset = CGSize(width: 0, height: -1)
        shadowLayer.shadowOpacity = 1
        layer?.addSublayer(shadowLayer)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var cornerRadius: CGFloat = 8 {
        didSet { needsLayout = true }
    }

    override var wantsUpdateLayer: Bool { true }

    func updateSurface(curve: Motion.Curve?) {
        CATransaction.begin()
        if let curve, !Motion.reduced {
            CATransaction.setAnimationDuration(curve.duration)
            CATransaction.setAnimationTimingFunction(curve.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = InspectorTheme.surface.cgColor
            shadowLayer.backgroundColor = InspectorTheme.surface.cgColor
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        content.layer?.cornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.cornerRadius = cornerRadius
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = InspectorTheme.surface.cgColor
            shadowLayer.backgroundColor = InspectorTheme.surface.cgColor
        }
        shadowLayer.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.25 : 0.06).cgColor
        content.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        content.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.6)).cgColor
    }
}

@MainActor
final class InspectorHeaderView: WindowDragView {
    private let store: BrowserStore
    private var tabs: [InspectorPanelKind: InspectorTabButton] = [:]
    private let pick = SymbolButton("cursorarrow.rays", size: 13)
    private let more = SymbolButton("ellipsis", size: 13)
    private let close = SymbolButton("sidebar.right", size: 13)

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        for kind in InspectorPanelKind.allCases {
            let tab = InspectorTabButton(kind) { [weak store] in store?.showInspector(kind) }
            tabs[kind] = tab
            addSubview(tab)
        }
        pick.toolTip = "Pick an element in the page  ⌥⌘C"
        pick.action = { [weak store] in store?.togglePicking() }
        more.toolTip = "More tools"
        more.action = { [weak self] in self?.showMore() }
        close.toolTip = "Close Developer Tools  ⌥⌘I"
        close.action = { [weak store] in store?.closeInspector() }
        for view in [pick, more, close] { addSubview(view) }
        store.observe(self) { [weak self] change in
            if case .developer = change { self?.update() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private weak var console: ConsoleModel?

    func update() {
        for (kind, tab) in tabs { tab.selected = kind == store.inspectorPanel }
        let model = store.inspectorSession?.model(ConsoleModel.self)
        if model !== console {
            console?.changed.stopObserving(self)
            console = model
            model?.changed.observe(self) { [weak self] in self?.updateBadge() }
        }
        updateBadge()
        pick.layer?.backgroundColor = store.visibleDevState.picking ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        pick.layer?.cornerRadius = 6
        needsLayout = true
    }

    private func updateBadge() {
        let errors = console?.errorCount ?? 0
        let badge = errors > 0 ? errors : nil
        guard tabs[.console]?.badge != badge else { return }
        tabs[.console]?.badge = badge
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let buttons: CGFloat = 28 * 3 + 4
        var x: CGFloat = 0
        let available = bounds.width - buttons - 4
        let full = InspectorPanelKind.allCases.map { tabs[$0]!.fullWidth }.reduce(0, +) + 2 * 5
        let compact = full > available
        for kind in InspectorPanelKind.allCases {
            let tab = tabs[kind]!
            tab.compact = compact && !(tab.selected && available - (full - tab.fullWidth + 28 * 5) > tab.fullWidth)
            let width = tab.compact ? 30 : tab.fullWidth
            tab.frame = NSRect(x: x, y: 8, width: width, height: 26)
            x += width + 2
        }
        var right = bounds.width
        for button in [close, more, pick] {
            right -= 28
            button.frame = NSRect(x: right, y: 9, width: 28, height: 24)
        }
    }

    private func showMore() {
        let menu = NSMenu()
        menu.add("Open Chrome DevTools") { [weak store] in store?.openChromeDevTools() }
        menu.add("Clear Site Data and Reload") { [weak store] in store?.clearSiteData() }
        menu.addItem(.separator())
        menu.add("Developer Settings…") { [weak store] in store?.openSettings?(.developer) }
        more.popUp(menu)
    }
}

final class InspectorTabButton: HoverView {
    let kind: InspectorPanelKind
    var selected = false {
        didSet { if selected != oldValue { needsDisplay = true; updateColors() } }
    }
    var compact = false {
        didSet { if compact != oldValue { title.isHidden = compact; needsLayout = true } }
    }
    var badge: Int? {
        didSet {
            guard badge != oldValue else { return }
            badgeLabel.stringValue = badge.map { $0 > 99 ? "99+" : "\($0)" } ?? ""
            badgeLabel.isHidden = badge == nil
            needsLayout = true
        }
    }
    private let icon = NSImageView()
    private let title: NSTextField
    private let badgeLabel = Label.chip()
    private let fill = FillLayer()
    private let click: () -> Void

    init(_ kind: InspectorPanelKind, click: @escaping () -> Void) {
        self.kind = kind
        self.click = click
        title = Label.make(kind.title, size: 12, weight: .medium, color: .secondaryLabelColor)
        super.init(frame: .zero)
        toolTip = kind.title
        layer?.addSublayer(fill)
        fill.cornerRadius = 7
        icon.image = .symbol(kind.symbol, size: 11, weight: .semibold)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(title)
        badgeLabel.font = Theme.font(9.5, .bold)
        badgeLabel.textColor = .white
        badgeLabel.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeLabel.layer?.cornerRadius = 6
        badgeLabel.isHidden = true
        addSubview(badgeLabel)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fullWidth: CGFloat { title.textWidth + 34 + (badge == nil ? 0 : 18) }

    private func updateColors() {
        icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        title.textColor = selected ? .labelColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        if compact {
            icon.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            badgeLabel.frame = NSRect(x: bounds.width - 13, y: 1, width: 14, height: 12)
        } else {
            icon.frame = NSRect(x: 8, y: 0, width: 16, height: bounds.height)
            title.frame = NSRect(x: 27, y: (bounds.height - 16) / 2, width: title.textWidth, height: 16)
            badgeLabel.frame = NSRect(x: title.frame.maxX + 2, y: (bounds.height - 13) / 2, width: 16, height: 13)
        }
    }

    override func updateLayer() {
        fill.paint(fill: selected ? Theme.selectedFill : hovering ? Theme.hoverFill : nil,
                   shadow: selected ? Theme.selectedShadow : nil, in: effectiveAppearance)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { click() }
    }
}

final class InspectorResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}
