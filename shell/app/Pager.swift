import AppKit

@MainActor
final class PagerModel {
    private(set) var position: CGFloat = 0
    private(set) var destination: CGFloat?
    private(set) var travel: ClosedRange<CGFloat>?
    weak var view: NSView?

    private struct Observer {
        weak var owner: AnyObject?
        let handle: @MainActor () -> Void
    }
    private var observers: [Observer] = []

    func observe(_ owner: AnyObject, _ handle: @escaping @MainActor () -> Void) {
        observers.append(Observer(owner: owner, handle: handle))
    }

    func setPosition(_ value: CGFloat, animated: Bool) {
        if animated, !Motion.reduced, view?.window != nil {
            guard value != (destination ?? position) else { return }
            move(to: value)
            return
        }
        stopMoving()
        guard value != position else { return }
        position = value
        notify()
    }

    private func notify() {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handle() }
    }

    private lazy var ticker = FrameTicker("space switch") { [weak self] time in self?.step(at: time) }
    private var moveStart: CFTimeInterval?
    private var moveFrom: CGFloat = 0

    private func move(to value: CGFloat) {
        moveFrom = position
        moveStart = nil
        destination = value
        travel = min(position, value)...max(position, value)
        if let view { ticker.start(on: view) }
    }

    private func step(at time: CFTimeInterval) {
        guard let destination else { return }
        let start = moveStart ?? time - 1.0 / 120
        moveStart = start
        let t = min(max((time - start) / Motion.glide.duration, 0), 1)
        position = t >= 1 ? destination : moveFrom + (destination - moveFrom) * CGFloat(Motion.glide.progress(at: t))
        if t >= 1 { stopMoving() }
        notify()
    }

    private func stopMoving() {
        ticker.stop()
        destination = nil
        travel = nil
    }

    var pageCount = 1
    var pageWidth: CGFloat = 260
    weak var sidebar: NSView?
    var onSettle: ((Int) -> Void)?
    var onSwipeTowards: ((Int) -> Void)?

    private enum Tracking {
        case idle
        case undecided(dx: CGFloat, dy: CGFloat)
        case horizontal(start: CGFloat, dx: CGFloat, velocity: CGFloat)
        case vertical
        case momentum
    }

    private var tracking = Tracking.idle

    var isTracking: Bool {
        switch tracking {
        case .horizontal, .momentum: true
        default: false
        }
    }

    func show(_ index: Int, animated: Bool) {
        guard !isTracking, (destination ?? position) != CGFloat(index) else { return }
        setPosition(CGFloat(index), animated: animated)
    }

    private var lastWheelStep: TimeInterval = 0

    private func inSidebar(_ event: NSEvent) -> Bool {
        guard let sidebar, sidebar.window === event.window, !sidebar.isHiddenOrHasHiddenAncestor else { return false }
        return sidebar.bounds.contains(sidebar.convert(event.locationInWindow, from: nil))
    }

    func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return handleWheel(event) }

        if event.phase.contains(.began) {
            tracking = inSidebar(event) && pageCount > 1 ? .undecided(dx: 0, dy: 0) : .idle
        }
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)

        switch tracking {
        case .idle, .vertical:
            if ended { tracking = .idle }
            return false

        case .undecided(var dx, var dy):
            dx += event.scrollingDeltaX
            dy += event.scrollingDeltaY
            if abs(dx) > 6, abs(dx) > abs(dy) * 1.2 {
                stopMoving()
                onSwipeTowards?(Int(position.rounded()) + (dx < 0 ? 1 : -1))
                tracking = .horizontal(start: position, dx: dx, velocity: event.scrollingDeltaX)
                setPosition(rubberBand(position - dx / pageWidth), animated: false)
                return true
            }
            tracking = ended ? .idle : abs(dy) > 6 ? .vertical : .undecided(dx: dx, dy: dy)
            return false

        case .horizontal(let start, var dx, let velocity):
            dx += event.scrollingDeltaX
            if ended {
                settle(from: start - dx / pageWidth, velocity: velocity)
                tracking = .momentum
            } else {
                tracking = .horizontal(start: start, dx: dx, velocity: event.scrollingDeltaX)
                setPosition(rubberBand(start - dx / pageWidth), animated: false)
            }
            return true

        case .momentum:
            if event.momentumPhase.isEmpty && event.phase.isEmpty {
                tracking = .idle
                return false
            }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                tracking = .idle
            }
            return true
        }
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.shift), dx == 0 { (dx, dy) = (dy, 0) }
        guard pageCount > 1, abs(dx) >= 1, abs(dx) > abs(dy), inSidebar(event) else { return false }
        guard event.timestamp - lastWheelStep > 0.35 else { return true }
        lastWheelStep = event.timestamp
        let current = Int((destination ?? position).rounded())
        let target = min(max(current + (dx < 0 ? 1 : -1), 0), pageCount - 1)
        guard target != current else { return true }
        setPosition(CGFloat(target), animated: true)
        onSettle?(target)
        return true
    }

    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        let last = CGFloat(pageCount - 1)
        if raw < 0 { return raw / 3 }
        if raw > last { return last + (raw - last) / 3 }
        return raw
    }

    private func settle(from raw: CGFloat, velocity: CGFloat) {
        var target = raw.rounded()
        if abs(velocity) > 6 {
            target = velocity > 0 ? raw.rounded(.down) : raw.rounded(.up)
        }
        let index = Int(min(max(target, 0), CGFloat(pageCount - 1)))
        setPosition(CGFloat(index), animated: true)
        onSettle?(index)
    }
}

final class WebContainerView: NSView {
    private weak var current: MBWebView?
    var viewport: ((MBWebView) -> NSSize?)?
    var onPageAreaChange: (() -> Void)?
    private(set) var pageArea = NSRect.zero
    private let devToolsEdge = NSView()
    private let devToolsBacking = NSView()
    private lazy var devToolsHeader = DevToolsHeaderView { [weak self] in self?.current?.closeDevTools() }
    private weak var dockedWindow: NSWindow?
    private lazy var devToolsHandle = DevToolsResizeHandle { [weak self] x in self?.resizeDevTools(to: x) }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set {
            layer?.cornerRadius = newValue
            layer?.cornerCurve = .continuous
        }
    }

    override func layout() {
        super.layout()
        placeCurrent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeCurrent()
    }

    func setBorder(_ color: NSColor?) {
        layer?.borderWidth = color == nil ? 0 : 1 / (window?.backingScaleFactor ?? 2)
        layer?.borderColor = color?.cgColor
    }

    func add(_ view: MBWebView) {
        view.isHidden = true
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    func show(_ view: MBWebView?, crossfade: Bool = false) {
        guard view !== current else { return }
        let previous = current?.superview === self ? current : nil
        let view = view?.superview === self ? view : nil
        if let view {
            view.layer?.removeAnimation(forKey: "opacity")
            view.alphaValue = 1
            view.layer?.zPosition = 0
            view.isHidden = false
        }
        current = view
        placeCurrent()
        guard let previous else {
            if crossfade, let view, !Motion.reduced {
                view.alphaValue = 0
                Motion.animate(Motion.fade) { view.animator().alphaValue = 1 }
            }
            return
        }
        guard crossfade, !Motion.reduced else {
            previous.isHidden = true
            return
        }
        previous.layer?.zPosition = 1
        Motion.animate(Motion.fade) {
            previous.animator().alphaValue = 0
        } completion: { [weak self, weak previous] in
            guard let previous else { return }
            previous.layer?.zPosition = 0
            previous.alphaValue = 1
            if previous !== self?.current { previous.isHidden = true }
        }
    }
}

extension WebContainerView {
    func renderBehind(_ view: MBWebView) -> () -> Void {
        guard view.superview === self, view !== current else { return {} }
        view.layer?.zPosition = -1
        view.frame = pageArea == .zero ? bounds : pageArea
        view.isHidden = false
        return { [weak self, weak view] in
            guard let view, view !== self?.current else { return }
            view.isHidden = true
            view.layer?.zPosition = 0
        }
    }

    func viewportChanged() {
        placeCurrent()
        guard let current, !Motion.reduced, window != nil else { return }
        current.alphaValue = 0
        Motion.animate(Motion.settle) { current.animator().alphaValue = 1 }
    }

    func placeCurrent() {
        let area = placeDevTools()
        if area != pageArea {
            pageArea = area
            onPageAreaChange?()
        }
        guard let current else { return }
        guard let size = viewport?(current) else {
            if current.frame != area { current.frame = area }
            if current.layer?.cornerRadius != 0 { setPreview(current, radius: 0) }
            return
        }
        let top = DevToolbarView.height, margin: CGFloat = 16
        let width = min(size.width, area.width - 2 * margin)
        let height = min(size.height, area.height - top - margin)
        let frame = NSRect(x: (area.minX + (area.width - width) / 2).rounded(), y: top,
                           width: max(width, 0), height: max(height, 0))
        if current.frame != frame { current.frame = frame }
        setPreview(current, radius: min(size.width, size.height) < 500 ? 24 : 12)
    }

    private func placeDevTools() -> NSRect {
        guard DeveloperSettings.docksDevTools, let window, let devTools = current?.devToolsWindow else {
            undock()
            devToolsEdge.isHidden = true
            devToolsBacking.isHidden = true
            devToolsHeader.isHidden = true
            devToolsHandle.isHidden = true
            return bounds
        }
        let saved = CGFloat(UserDefaults.standard.double(forKey: DeveloperSettings.devToolsWidthKey))
        let width = min(max(saved > 0 ? saved : 440, 280), max(bounds.width - 320, 280))
        let edge = (bounds.width - width).rounded()
        if devToolsEdge.superview !== self {
            devToolsEdge.wantsLayer = true
            devToolsBacking.wantsLayer = true
            addSubview(devToolsBacking)
            addSubview(devToolsHeader)
            addSubview(devToolsEdge)
            addSubview(devToolsHandle)
        }
        for view in [devToolsBacking, devToolsHeader, devToolsEdge, devToolsHandle] {
            view.layer?.zPosition = 2
            view.isHidden = false
        }
        let dark = effectiveAppearance.isDark
        devToolsBacking.frame = NSRect(x: edge, y: 0, width: bounds.width - edge, height: bounds.height)
        devToolsBacking.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.157, green: 0.157, blue: 0.157, alpha: 1) : .white).cgColor
        devToolsEdge.frame = NSRect(x: edge, y: 0, width: 1, height: bounds.height)
        devToolsEdge.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.12).cgColor
        devToolsHandle.frame = NSRect(x: edge - 3, y: 0, width: 7, height: bounds.height)
        if dockedWindow !== devTools {
            undock()
            dock(devTools, in: window)
        }
        let header = DevToolsHeaderView.height
        devToolsHeader.frame = NSRect(x: edge + 1, y: 0, width: bounds.width - edge - 1, height: header)
        devToolsHeader.dark = dark
        let panel = NSRect(x: edge + 1, y: header, width: bounds.width - edge - 1, height: bounds.height - header)
        let frame = window.convertToScreen(convert(panel, to: nil))
        if devTools.frame != frame { devTools.setFrame(frame, display: true) }
        devTools.contentView?.layer?.cornerRadius = cornerRadius
        return NSRect(x: 0, y: 0, width: edge, height: bounds.height)
    }

    private func dock(_ devTools: NSWindow, in window: NSWindow) {
        devTools.styleMask = [.borderless, .resizable]
        devTools.isOpaque = false
        devTools.backgroundColor = .clear
        devTools.isMovable = false
        devTools.hasShadow = false
        if let content = devTools.contentView {
            content.wantsLayer = true
            content.layer?.cornerCurve = .continuous
            content.layer?.maskedCorners = [.layerMaxXMinYCorner]
            content.layer?.masksToBounds = true
        }
        if ProcessInfo.processInfo.environment["MBGA_DEBUG_EVENTS"] != nil {
            NSLog("docked DevTools: canBecomeKey=%d", devTools.canBecomeKey ? 1 : 0)
        }
        devTools.collectionBehavior.insert(.fullScreenAuxiliary)
        window.addChildWindow(devTools, ordered: .above)
        devTools.orderFront(nil)
        dockedWindow = devTools
    }

    private func undock() {
        guard let devTools = dockedWindow else { return }
        dockedWindow = nil
        devTools.parent?.removeChildWindow(devTools)
        if DeveloperSettings.docksDevTools {
            devTools.orderOut(nil)
            return
        }
        devTools.contentView?.layer?.cornerRadius = 0
        devTools.contentView?.layer?.masksToBounds = false
        devTools.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        devTools.isOpaque = true
        devTools.backgroundColor = .windowBackgroundColor
        devTools.isMovable = true
        devTools.hasShadow = true
        devTools.setFrame(devTools.frame.insetBy(dx: -20, dy: -20).offsetBy(dx: -60, dy: 0), display: true)
    }

    private func resizeDevTools(to x: CGFloat) {
        UserDefaults.standard.set(Double(bounds.width - x), forKey: DeveloperSettings.devToolsWidthKey)
        placeCurrent()
    }

    private func setPreview(_ view: MBWebView, radius: CGFloat) {
        let preview = radius > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = preview
        view.layer?.borderWidth = preview ? 1 / (window?.backingScaleFactor ?? 2) : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.borderColor = Theme.faint(0.18).cgColor
            layer?.backgroundColor = preview
                ? NSColor(name: nil) { $0.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1) }.cgColor
                : NSColor.white.cgColor
        }
        CATransaction.commit()
    }
}

final class DevToolsHeaderView: FlippedView {
    static let height: CGFloat = 30
    var dark = true {
        didSet { if dark != oldValue { needsDisplay = true } }
    }
    private let title = Label.make("Developer Tools", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let close: SymbolButton
    private let line = CALayer()

    init(close: @escaping () -> Void) {
        self.close = SymbolButton("xmark", size: 11, action: close)
        super.init(frame: .zero)
        wantsLayer = true
        self.close.toolTip = "Close Developer Tools  ⌥⌘I"
        addSubview(title)
        addSubview(self.close)
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(bounds.width - 60, 0), height: 16)
        close.frame = NSRect(x: bounds.width - 34, y: (bounds.height - 24) / 2, width: 28, height: 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func updateLayer() {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.157, green: 0.157, blue: 0.157, alpha: 1) : .white).cgColor
        line.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
}

final class DevToolsResizeHandle: NSView {
    private let onDrag: (CGFloat) -> Void

    init(onDrag: @escaping (CGFloat) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag(superview.convert(event.locationInWindow, from: nil).x)
    }
}

final class PageCardView: NSView {
    let container: WebContainerView
    private let shadowLayer = CALayer()

    init(container: WebContainerView) {
        self.container = container
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.backgroundColor = NSColor.white.cgColor
        shadowLayer.cornerCurve = .continuous
        shadowLayer.shadowRadius = 6
        shadowLayer.shadowOffset = CGSize(width: 0, height: -1)
        shadowLayer.shadowOpacity = 1
        layer?.addSublayer(shadowLayer)
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    var isCard = true {
        didSet { if isCard != oldValue { needsDisplay = true; needsLayout = true } }
    }
    var cornerRadius: CGFloat = 8 {
        didSet { if cornerRadius != oldValue { needsDisplay = true; needsLayout = true } }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.cornerRadius = isCard ? cornerRadius : 0
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: shadowLayer.cornerRadius,
                                        cornerHeight: shadowLayer.cornerRadius, transform: nil)
        shadowLayer.isHidden = !isCard
        CATransaction.commit()
        container.cornerRadius = isCard ? cornerRadius : 0
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        shadowLayer.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.07).cgColor
        container.setBorder(isCard ? (dark ? .white.withAlphaComponent(0.1) : .black.withAlphaComponent(0.08)) : nil)
    }
}
