import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class HoverView: FlippedView {
    private(set) var hovering = false {
        didSet { if hovering != oldValue { hoverChanged() } }
    }
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
        hovering = isUnderPointer
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovering = false }
    }

    func hoverChanged() {
        FillLayer.animated(Motion.quick) { updateLayer() }
    }
}

@MainActor
final class FrameTicker {
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    private let name: String
    private let tick: @MainActor (CFTimeInterval) -> Void

    init(_ name: String, _ tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.name = name
        self.tick = tick
    }

    var isRunning: Bool { link != nil }

    func start(on view: NSView) {
        guard link == nil else { return }
        window = view.window
        let link = view.displayLink(target: Target(self), selector: #selector(Target.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        stats = Stats()
    }

    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        if Self.debug { stats.report(name, visible: window?.occlusionState.contains(.visible) == true) }
    }

    private func step(_ link: CADisplayLink) {
        guard Self.debug else {
            tick(link.targetTimestamp)
            return
        }
        let start = CACurrentMediaTime()
        tick(link.targetTimestamp)
        stats.add(shown: link.timestamp, frame: link.targetTimestamp - link.timestamp, work: CACurrentMediaTime() - start)
    }

    private static let debug = ProcessInfo.processInfo.environment["MBGA_DEBUG_FPS"]?.isEmpty == false
    private var stats = Stats()

    private struct Stats {
        var frames = 0
        var late = 0
        var longestGap: CFTimeInterval = 0
        var frame: CFTimeInterval = 0
        var work: CFTimeInterval = 0
        var longestWork: CFTimeInterval = 0
        var lastShown: CFTimeInterval?

        mutating func add(shown: CFTimeInterval, frame: CFTimeInterval, work: CFTimeInterval) {
            frames += 1
            self.frame = frame
            self.work += work
            longestWork = max(longestWork, work)
            if let lastShown {
                let gap = shown - lastShown
                longestGap = max(longestGap, gap)
                if gap > frame * 1.5 { late += 1 }
            }
            lastShown = shown
        }

        func report(_ name: String, visible: Bool) {
            guard frames > 0 else { return }
            NSLog("MBGA fps %@: %d frames at %.0f Hz, %d late, longest gap %.1f ms, work avg %.2f ms max %.2f ms, visible %d",
                  name, frames, frame > 0 ? 1 / frame : 0, late, longestGap * 1000, work / Double(frames) * 1000,
                  longestWork * 1000, visible ? 1 : 0)
        }
    }

    private final class Target: NSObject {
        weak var ticker: FrameTicker?

        init(_ ticker: FrameTicker) { self.ticker = ticker }

        @MainActor @objc func step(_ link: CADisplayLink) { ticker?.step(link) }
    }
}

extension NSView {
    var isUnderPointer: Bool {
        guard let window, window.isKeyWindow, let content = window.contentView else { return false }
        let point = window.mouseLocationOutsideOfEventStream
        guard visibleRect.contains(convert(point, from: nil)) else { return false }
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)?.isDescendant(of: self) == true
    }
}

final class FillLayer: CALayer {
    private nonisolated(unsafe) static var animating = false

    @MainActor
    static func animated(_ curve: Motion.Curve, _ changes: () -> Void) {
        animating = !Motion.reduced
        CATransaction.begin()
        CATransaction.setAnimationDuration(curve.duration)
        CATransaction.setAnimationTimingFunction(curve.timing)
        changes()
        CATransaction.commit()
        animating = false
    }

    override init() {
        super.init()
        cornerCurve = .continuous
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func action(forKey event: String) -> CAAction? {
        Self.animating ? super.action(forKey: event) : NSNull()
    }

    func paint(fill: NSColor?, border: NSColor? = nil, shadow: NSColor? = nil, in appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor = fill?.cgColor
            borderColor = border?.cgColor
            borderWidth = border == nil ? 0 : 1
            shadowColor = shadow?.cgColor
            shadowOpacity = shadow == nil ? 0 : 1
            shadowRadius = 1.5
            shadowOffset = CGSize(width: 0, height: -0.5)
        }
    }
}

extension NSTextField {
    func setIfChanged(_ text: String) {
        if stringValue != text { stringValue = text }
    }

    var textWidth: CGFloat { ceil(attributedStringValue.size().width) + 4 }
}

enum Label {
    static func make(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.font(size, weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    static func chip(_ text: String = "") -> NSTextField {
        let label = NSTextField(frame: .zero)
        label.cell = CenteredTextCell(textCell: text)
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = Theme.font(11, .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.cornerCurve = .continuous
        return label
    }

    static func wrapping(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.font(size)
        label.textColor = color
        label.isSelectable = false
        return label
    }
}

private final class CenteredTextCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        let height = min(cellSize(forBounds: rect).height, title.height)
        title.origin.y += (title.height - height) / 2
        title.size.height = height
        return title
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

final class SymbolButton: HoverView {
    var action: (() -> Void)?
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 0.8 : 0.35; needsDisplay = true }
    }
    private let imageView = NSImageView()
    private let fill = FillLayer()

    init(_ symbol: String, size: CGFloat = 13, action: (() -> Void)? = nil) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        layer?.addSublayer(fill)
        fill.cornerRadius = 6
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
        setSymbol(symbol, size: size)
        alphaValue = 0.8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ name: String, size: CGFloat = 13) {
        imageView.image = .symbol(name, size: size)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        imageView.frame = bounds
    }

    override func updateLayer() {
        fill.paint(fill: hovering && isEnabled ? Theme.hoverFill : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.55
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        alphaValue = 0.8
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

class WindowDragView: FlippedView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class ClosureTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

private nonisolated(unsafe) var closureTargetKey: UInt8 = 0

extension NSControl {
    func onAction(_ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        objc_setAssociatedObject(self, &closureTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        self.action = #selector(ClosureTarget.fire(_:))
    }
}

extension NSButton {
    static func push(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .push
        button.onAction(action)
        return button
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, state: Bool? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(action)
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        if let state { item.state = state ? .on : .off }
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(titled title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let menu = NSMenu(title: title)
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        addItem(item)
        return item
    }
}

extension NSView {
    func setVisible(_ visible: Bool, animated: Bool, curve: Motion.Curve = Motion.quick) {
        guard animated, window != nil, !Motion.reduced else {
            layer?.removeAnimation(forKey: "alphaValue")
            isHidden = !visible
            alphaValue = 1
            return
        }
        if visible, !isHidden, alphaValue == 1 { return }
        if !visible, isHidden { return }
        fade(visible: visible, curve: curve)
    }

    func fade(visible: Bool, curve: Motion.Curve = Motion.quick) {
        if visible, isHidden {
            alphaValue = 0
            isHidden = false
        }
        Motion.animate(curve) { animator().alphaValue = visible ? 1 : 0 } completion: { [weak self] in
            if !visible, let self, alphaValue == 0 { isHidden = true }
        }
    }
}
