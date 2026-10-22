import AppKit

@MainActor
final class RootView: NSView {
    private let store: BrowserStore
    private let backdrop = BackdropView()
    private let sidebar: SidebarView
    private lazy var rail = SidebarRail(store: store)
    private let handle = SidebarResizeHandle()
    private let card: PageCardView
    private let emptyHint: EmptySpaceHintView
    private let elsewhereHint: ElsewhereHintView
    private let dropPreview = DropPreviewView()
    private let devToolbar: DevToolbarView
    private let inspector: InspectorView
    private let inspectorHandle = InspectorResizeHandle()
    private let agentGlow = AgentGlowView()
    private let peek = PeekContainerView()
    private let smear = MotionSmearView()
    private let toast: ToastView
    private var commandBar: CommandBarView?
    private var sheets = SheetPresenter()
    private var shownLayout: SidebarLayout

    init(store: BrowserStore) {
        self.store = store
        sidebar = SidebarView(store: store)
        card = PageCardView(container: store.webContainer)
        emptyHint = EmptySpaceHintView(store: store)
        elsewhereHint = ElsewhereHintView(store: store)
        devToolbar = DevToolbarView(store: store)
        inspector = InspectorView(store: store)
        toast = ToastView(store: store)
        shownLayout = store.layout
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        wantsLayer = true
        addSubview(backdrop)
        addSubview(inspector)
        addSubview(inspectorHandle)
        addSubview(card)
        inspector.isHidden = !store.inspectorOpen
        inspectorHandle.onDrag = { [weak self] x in self?.resizeInspector(to: x) }
        card.addSubview(emptyHint)
        card.addSubview(elsewhereHint)
        card.addSubview(dropPreview)
        card.addSubview(devToolbar)
        card.addSubview(agentGlow)
        emptyHint.autoresizingMask = [.width, .height]
        elsewhereHint.autoresizingMask = [.width, .height]
        dropPreview.autoresizingMask = [.width, .height]
        dropPreview.isHidden = true
        addSubview(smear)
        addSubview(peek)
        peek.isHidden = true
        addSubview(sidebar)
        addSubview(handle)
        addSubview(toast)
        toast.isHidden = true
        if store.layout == .compact { addSubview(rail, positioned: .above, relativeTo: card) }
        handle.onResize = { [weak self] in self?.needsLayout = true }
        store.webContainer.onPageAreaChange = { [weak self] in self?.needsLayout = true }

        store.observe(self) { [weak self] change in self?.handle(change) }
        store.pager.observe(self) { [weak self] in self?.updateBackdrop(nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        updateEmptyHint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func handle(_ change: StoreChange) {
        switch change {
        case .snapshot:
            let sameSpace = store.snapshot.activeSpace == backdropSpace
            backdropSpace = store.snapshot.activeSpace
            updateBackdrop(store.snapshotAnimation ?? (sameSpace ? Motion.quick : nil))
            updateEmptyHint()
        case .pageColors:
            updateBackdrop(Motion.quick)
        case .layout:
            transitionLayout()
        case .peek:
            updatePeek()
        case .commandBar:
            updateCommandBar()
            updateEmptyHint()
        case .elsewhere:
            elsewhereHint.update()
            updateEmptyHint()
        case .toast:
            updateToast()
        case .agent:
            agentGlow.setActive(store.agentActingOnVisibleTab)
        case .dragOverPage:
            updateDropPreview()
        case .inspector:
            transitionInspector()
        case .chrome:
            Motion.animate(Motion.settle) {
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
        case .spaceEditor:
            if let window { sheets.showSpaceEditor(store.spaceEditor, store: store, in: window) }
        case .importSheet:
            if let window { sheets.showImport(store.importSheet, store: store, in: window) }
        default:
            break
        }
    }

    @objc private func defaultsChanged() {
        updateBackdrop(Motion.quick)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            center.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
        }
        updateBackdrop(nil)
    }

    @objc private func windowStateChanged() {
        updateBackdrop(Motion.quick)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackdrop(nil)
    }

    private func updateBackdrop(_ curve: Motion.Curve?) {
        let dark = effectiveAppearance.isDark
        let colors = store.tintColors(matchPage: UserDefaults.standard.bool(forKey: TintStyle.matchPageKey), dark: dark)
        let active = window.map { $0.isKeyWindow || $0.isMainWindow || NSApp.keyWindow?.parent === $0 } ?? true
        let tint = Theme.gradient(for: Theme.blend(colors, at: store.pager.position), dark: dark, active: active,
                                  style: TintStyle.saved)
        inspector.setTint(tint, curve: curve)
        let stops = tint.map(\.cgColor)
        backdrop.setColors(stops, curve: curve)
        peek.backdrop.setColors(stops, curve: curve)
        smear.colors = stops
    }

    private var backdropSpace: UInt64?

    private func updateEmptyHint() {
        let visible = store.visibleTabID == nil && store.commandBar == nil
        if visible { emptyHint.update() }
        emptyHint.setVisible(visible, animated: true, curve: Motion.fade)
        elsewhereHint.setVisible(store.visibleTabElsewhere && store.commandBar == nil, animated: true, curve: Motion.fade)
    }

    private var chrome: Bool { !store.contentFullscreen }
    private var sidebarWidth: CGFloat { handle.width }
    private var inset: CGFloat { store.layout == .focus ? 5 : 8 }

    private func cardFrame(for layout: SidebarLayout) -> NSRect {
        guard chrome else { return bounds }
        let inset: CGFloat = layout == .focus ? 5 : 8
        let leading: CGFloat = switch layout {
        case .full: sidebarWidth + 8
        case .compact: SidebarRail.width
        case .focus: inset
        }
        return NSRect(x: leading, y: inset, width: max(bounds.width - leading - inset, 0),
                      height: max(bounds.height - inset * 2, 0))
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        card.frame = currentCardFrame
        card.isCard = chrome
        let panels = min(sidebarSpring.value + railSpring.value, 1)
        card.cornerRadius = max(store.windowRadius - (5 + 3 * panels), 6)
        emptyHint.frame = card.bounds
        elsewhereHint.frame = card.bounds
        dropPreview.frame = card.bounds
        let page = store.webContainer.pageArea
        agentGlow.frame = card.bounds
        agentGlow.cornerRadius = card.isCard ? card.cornerRadius : 0
        devToolbar.frame = NSRect(x: 0, y: card.bounds.height - DevToolbarView.height,
                                  width: page.width > 0 ? page.width : card.bounds.width, height: DevToolbarView.height)
        layoutInspector()
        let shown = sidebarShown, peeking = peekSpring.value
        if shownLayout == .full || shown > 0.001 {
            sidebar.frame = NSRect(x: -sidebarWidth * (1 - shown), y: 0, width: sidebarWidth, height: bounds.height)
            sidebar.alphaValue = shown
        } else {
            sidebar.frame = peekFrame(at: peeking)
            sidebar.alphaValue = 1
        }
        sidebar.isHidden = !chrome
        peek.isHidden = !chrome || peeking == 0 || shownLayout == .full
        if !peek.isHidden { peek.frame = peekFrame(at: peeking) }
        store.offsetTrafficLights(peek.isHidden ? .zero
            : CGSize(width: max(peek.frame.minX, 0), height: peek.frame.minY * min(max(peeking, 0), 1)))
        if rail.superview === self {
            let shown = railShown
            rail.frame = NSRect(x: -SidebarRail.width * (1 - shown), y: 0, width: SidebarRail.width, height: bounds.height)
            rail.alphaValue = shown
            rail.isHidden = !chrome || shown == 0
        }
        handle.isHidden = !(chrome && shownLayout == .full)
        handle.frame = NSRect(x: sidebarWidth, y: 0, width: 8, height: bounds.height)
        if !peek.isHidden {
            smear.update(edge: peek.frame, cornerRadius: peek.cornerRadius,
                         speed: peekSpring.velocity * (sidebarWidth + 18))
        } else {
            smear.update(edge: .zero, cornerRadius: 0, speed: 0)
        }
        layoutToast()
        commandBar?.frame = bounds
    }

    private lazy var sidebarSpring = Spring(store.layout == .full ? 1 : 0)
    private lazy var railSpring = Spring(store.layout == .compact ? 1 : 0)
    private lazy var layoutTicker = FrameTicker("layout") { [weak self] time in self?.stepLayout(at: time) }
    private var lastLayoutStep: CFTimeInterval?

    private lazy var peekSpring = Spring(0, response: Motion.peekResponse)
    private lazy var inspectorSpring = Spring(store.inspectorOpen ? 1 : 0)
    private var sidebarShown: CGFloat { sidebarSpring.value }
    private var railShown: CGFloat { railSpring.value }

    private var currentCardFrame: NSRect {
        guard chrome else { return bounds }
        let sidebar = sidebarSpring.value, rail = railSpring.value
        let panels = min(sidebar + rail, 1)
        let inset = 5 + 3 * panels
        let leading = sidebar * (sidebarWidth + 8) + rail * SidebarRail.width + (1 - panels) * 5
        let trailing = inspectorSpring.value * (inspectorWidth + 8)
        return NSRect(x: leading, y: inset, width: max(bounds.width - leading - inset - trailing, 0),
                      height: max(bounds.height - inset * 2, 0))
    }

    private func transitionLayout() {
        let new = store.layout
        guard new != shownLayout else { return }
        shownLayout = new
        if new == .compact, rail.superview !== self { addSubview(rail, positioned: .above, relativeTo: card) }
        sidebarSpring.target = new == .full ? 1 : 0
        railSpring.target = new == .compact ? 1 : 0
        if new == .full, peekSpring.value > sidebarSpring.value {
            sidebarSpring.value = peekSpring.value
            sidebarSpring.velocity = peekSpring.velocity
        }
        if new == .full { peekSpring.settle() }
        guard chrome, !Motion.reduced, window != nil else {
            sidebarSpring.settle()
            railSpring.settle()
            finishLayoutMove()
            return
        }
        if !layoutTicker.isRunning { lastLayoutStep = nil }
        layoutTicker.start(on: self)
        needsLayout = true
    }

    private func stepLayout(at time: CFTimeInterval) {
        let dt = lastLayoutStep.map { time - $0 } ?? 1.0 / 120
        lastLayoutStep = time
        sidebarSpring.step(dt)
        railSpring.step(dt)
        peekSpring.step(dt)
        inspectorSpring.step(dt)
        if sidebarSpring.isSettled, railSpring.isSettled, peekSpring.isSettled, inspectorSpring.isSettled {
            finishLayoutMove()
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func finishLayoutMove() {
        layoutTicker.stop()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private var inspectorWidth: CGFloat {
        min(InspectorSettings.width, max(bounds.width - 420, InspectorSettings.minWidth))
    }

    private func layoutInspector() {
        let shown = inspectorSpring.value
        let width = inspectorWidth
        let visible = chrome && shown > 0.001
        inspector.isHidden = !visible
        inspectorHandle.isHidden = !visible || shown < 1
        guard visible else { return }
        let inset: CGFloat = 8
        let x = bounds.width - inset - shown * width + (1 - shown) * inset
        inspector.frame = NSRect(x: x.rounded(), y: 0, width: width, height: bounds.height)
        inspector.alphaValue = min(shown * 1.5, 1)
        inspector.cornerRadius = card.cornerRadius
        inspectorHandle.frame = NSRect(x: card.frame.maxX, y: 0, width: 8, height: bounds.height)
    }

    private func transitionInspector() {
        inspectorSpring.target = store.inspectorOpen ? 1 : 0
        if store.inspectorOpen { inspector.update() }
        guard chrome, !Motion.reduced, window != nil else {
            inspectorSpring.settle()
            finishLayoutMove()
            return
        }
        if !layoutTicker.isRunning { lastLayoutStep = nil }
        layoutTicker.start(on: self)
        needsLayout = true
    }

    private func resizeInspector(to x: CGFloat) {
        let width = bounds.width - 8 - x - 8
        UserDefaults.standard.set(Double(max(width, InspectorSettings.minWidth)), forKey: InspectorSettings.widthKey)
        needsLayout = true
    }

    private func peekFrame(at p: CGFloat) -> NSRect {
        let width = sidebarWidth
        let hidden = -width - 12, shown: CGFloat = 6
        return NSRect(x: hidden + (shown - hidden) * p, y: 6, width: width, height: max(bounds.height - 12, 0))
    }

    private func updatePeek() {
        peek.cornerRadius = max(store.windowRadius - 6, 8)
        peekSpring.target = store.sidebarPeek ? 1 : 0
        guard chrome, !Motion.reduced, window != nil else {
            peekSpring.settle()
            needsLayout = true
            return
        }
        if !layoutTicker.isRunning { lastLayoutStep = nil }
        layoutTicker.start(on: self)
        needsLayout = true
    }

    private func updateCommandBar() {
        if let mode = store.commandBar {
            guard commandBar == nil else { return }
            let bar = CommandBarView(store: store, mode: mode)
            bar.frame = bounds
            addSubview(bar, positioned: .above, relativeTo: nil)
            commandBar = bar
            bar.present()
        } else if let bar = commandBar {
            commandBar = nil
            bar.dismiss { bar.removeFromSuperview() }
        }
    }

    private func layoutToast() {
        let width = toast.preferredWidth
        let pageMid = chrome ? card.frame.midX : bounds.midX
        toast.frame = NSRect(x: pageMid - width / 2, y: bounds.height - 22 - 36, width: width, height: 36)
    }

    private func updateToast() {
        if let current = store.toast {
            toast.configure(current)
            if let commandBar {
                addSubview(toast, positioned: .below, relativeTo: commandBar)
            } else {
                addSubview(toast, positioned: .above, relativeTo: nil)
            }
            let shown = toast.frame
            layoutToast()
            let final = toast.frame
            if toast.isHidden {
                toast.frame = final.offsetBy(dx: 0, dy: 16)
                toast.alphaValue = 0
                toast.isHidden = false
            } else {
                toast.frame = shown
            }
            Motion.animate(Motion.settle) {
                toast.animator().frame = final
                toast.animator().alphaValue = 1
            }
        } else if !toast.isHidden {
            Motion.animate(Motion.quick) {
                toast.animator().alphaValue = 0
                toast.animator().frame.origin.y += 10
            } completion: { [weak self] in
                guard let self, store.toast == nil else { return }
                toast.isHidden = true
            }
        }
    }

    private func updateDropPreview() {
        if let id = store.dragOverPage, let tab = store.core.tab(id: id) {
            let appearing = dropPreview.isHidden
            dropPreview.configure(tab)
            dropPreview.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dropPreview.fade(visible: true, curve: Motion.settle)
            if appearing, !Motion.reduced, let layer = dropPreview.layer {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.96
                grow.toValue = 1
                grow.duration = Motion.settle.duration
                grow.timingFunction = Motion.settle.timing
                layer.add(grow, forKey: "grow")
            }
        } else {
            dropPreview.fade(visible: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class BackdropView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColors(_ colors: [CGColor], curve: Motion.Curve?) {
        CATransaction.begin()
        if let curve, !Motion.reduced {
            CATransaction.setAnimationDuration(curve.duration)
            CATransaction.setAnimationTimingFunction(curve.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        gradient.colors = colors
        CATransaction.commit()
    }
}

final class AgentGlowView: NSView {
    private let ring = CALayer()
    var cornerRadius: CGFloat = 8 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        ring.shadowRadius = 12
        ring.shadowOffset = .zero
        ring.shadowOpacity = 1
        ring.opacity = 0
        layer?.addSublayer(ring)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    func setActive(_ active: Bool) {
        let accent = NSColor.controlAccentColor
        ring.borderColor = accent.cgColor
        ring.shadowColor = accent.withAlphaComponent(0.8).cgColor
        if active { isHidden = false }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.presentation()?.opacity ?? ring.opacity
        fade.toValue = active ? 1 : 0
        fade.duration = Motion.reduced ? 0 : (active ? Motion.quick.duration : Motion.fade.duration * 2)
        ring.opacity = active ? 1 : 0
        ring.add(fade, forKey: "fade")
        if active, !Motion.reduced, ring.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "shadowRadius")
            breathe.fromValue = 6
            breathe.toValue = 16
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            ring.add(breathe, forKey: "breathe")
        } else if !active {
            DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration) { [weak self] in
                guard let self, ring.opacity == 0 else { return }
                ring.removeAnimation(forKey: "breathe")
                isHidden = true
            }
        }
    }
}

final class PeekContainerView: FlippedView {
    let backdrop = BackdropView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backdrop)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        backdrop.wantsLayer = true
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    var cornerRadius: CGFloat = 10 {
        didSet { backdrop.layer?.cornerRadius = cornerRadius; needsDisplay = true }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    override func updateLayer() {
        guard let layer, let back = backdrop.layer else { return }
        back.borderWidth = 0.5
        back.borderColor = Theme.faint(0.1).cgColor
        layer.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 4, height: 0)
    }
}

final class MotionSmearView: NSView {
    private let fill = CAGradientLayer()
    private let fade = CAGradientLayer()

    var colors: [CGColor] = [] {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.colors = colors
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [1, 0.55, 0.2, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        fade.locations = [0, 0.3, 0.65, 1]
        fill.mask = fade
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(edge: NSRect, cornerRadius: CGFloat, speed: CGFloat) {
        let length = min(abs(speed) * CGFloat(Motion.slow) / 55, 72)
        guard length >= 2, !Motion.reduced else {
            isHidden = true
            return
        }
        isHidden = false
        frame = NSRect(x: edge.maxX - 2, y: edge.minY + cornerRadius,
                       width: length + 2, height: max(edge.height - cornerRadius * 2, 0))
        alphaValue = min(length / 24, 1) * 0.9
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fade.frame = bounds
        CATransaction.commit()
    }
}

final class SidebarResizeHandle: NSView {
    static let range: ClosedRange<CGFloat> = 200...420
    var onResize: (() -> Void)?
    private var startWidth: CGFloat?
    private var startX: CGFloat = 0

    private(set) var width: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        return saved > 0 ? saved : 260
    }()

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startWidth = width
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startWidth else { return }
        width = Self.rubberBand(startWidth + event.locationInWindow.x - startX)
        onResize?()
    }

    override func mouseUp(with event: NSEvent) {
        startWidth = nil
        let clamped = min(max(width, Self.range.lowerBound), Self.range.upperBound)
        if clamped != width {
            width = clamped
            Motion.animate(Motion.settle) { superview?.layoutSubtreeIfNeeded(); onResize?(); superview?.layoutSubtreeIfNeeded() }
        }
        UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
    }

    private static func rubberBand(_ raw: CGFloat) -> CGFloat {
        if raw < range.lowerBound { return range.lowerBound - (range.lowerBound - raw) / 4 }
        if raw > range.upperBound { return range.upperBound + (raw - range.upperBound) / 4 }
        return raw
    }
}
