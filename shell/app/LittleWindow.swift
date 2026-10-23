import AppKit

@MainActor
final class LittleWindow: NSObject, NSWindowDelegate {
    let tabID: UInt64
    let window: NSWindow
    private weak var store: BrowserStore?
    private let content: LittleWindowView
    private var returnToSidebar = false

    init(tabID: UInt64, view: MBWebView, store: BrowserStore, near point: NSPoint?) {
        self.tabID = tabID
        self.store = store
        let size = NSSize(width: 560, height: 700)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.acceptsMouseMovedEvents = true
        content = LittleWindowView(tabID: tabID, store: store)
        super.init()
        window.delegate = self
        content.putBack = { [weak self] in self?.putBack() }
        window.contentView = content
        content.host(view, cornerRadius: max(window.systemCornerRadius - 6, 6))
        place(near: point)
    }

    func show() {
        guard !window.isVisible, !Motion.reduced else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let frame = window.frame
        window.setFrame(frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    func putBack() {
        returnToSidebar = true
        fadeOutAndClose()
    }

    private var closing = false

    private func fadeOutAndClose() {
        guard !closing else { return }
        closing = true
        guard !Motion.reduced, window.isVisible else {
            window.close()
            return
        }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.foldIn.duration
            context.timingFunction = Motion.foldIn.timing
            window.animator().setFrame(frame.insetBy(dx: frame.width * 0.04, dy: frame.height * 0.04), display: true)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.window.close() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        fadeOutAndClose()
        return false
    }

    func dismiss() {
        window.delegate = nil
        fadeOutAndClose()
    }

    func windowWillClose(_ notification: Notification) {
        store?.littleWindowClosed(tabID, select: returnToSidebar)
    }

    private func place(near point: NSPoint?) {
        guard let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            window.center()
            return
        }
        let size = window.frame.size
        let area = screen.visibleFrame
        let x = min(max(point.x - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(max(point.y - size.height / 2, area.minY), area.maxY - size.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class LittleWindowView: FlippedView {
    private let tabID: UInt64
    private let store: BrowserStore
    private let backdrop = BackdropView()
    private let bar = WindowDragView()
    private let icon = NSImageView()
    private let title = Label.make(size: 12.5, weight: .medium)
    private let host = Label.make(size: 12, color: .secondaryLabelColor)
    private let back = NSButton()
    private let container = NSView()
    var putBack: (() -> Void)?

    init(tabID: UInt64, store: BrowserStore) {
        self.tabID = tabID
        self.store = store
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        back.isBordered = false
        back.image = .symbol("sidebar.left", size: 12)
        back.imagePosition = .imageLeading
        back.attributedTitle = NSAttributedString(string: " Open in Sidebar", attributes: [
            .font: Theme.font(12, .medium), .foregroundColor: NSColor.labelColor,
        ])
        back.contentTintColor = .labelColor
        back.toolTip = "Put this tab back in the main window"
        back.onAction { [weak self] in self?.putBack?() }
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(backdrop)
        addSubview(bar)
        for view in [icon, title, host, back] as [NSView] { bar.addSubview(view) }
        addSubview(container)
        store.observe(self) { [weak self] change in
            if change == .snapshot { self?.update() }
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func host(_ view: NSView, cornerRadius: CGFloat) {
        container.layer?.cornerRadius = cornerRadius
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = false
        container.addSubview(view)
    }

    private func update() {
        guard let tab = store.core.tab(id: tabID) else { return }
        icon.image = FaviconCache.shared.image(for: tab)
        title.stringValue = tab.displayTitle
        host.stringValue = tab.host
        let space = store.snapshot.spaces.first { s in
            s.today.contains { $0.id == tabID } || s.pinned.contains { $0.id == tabID } || s.favorites.contains { $0.id == tabID }
        }
        let stops = Theme.gradient(for: RGB(space?.color ?? Theme.spaceColors[0]), dark: effectiveAppearance.isDark,
                                   active: true, style: TintStyle.saved)
        backdrop.setColors(stops.map(\.cgColor), curve: window?.isVisible == true ? Motion.fade : nil)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 36)
        icon.frame = NSRect(x: 74, y: 11, width: 14, height: 14)
        let backWidth = back.intrinsicContentSize.width + 8
        back.frame = NSRect(x: bounds.width - 10 - backWidth, y: 8, width: backWidth, height: 20)
        let available = back.frame.minX - 96 - 8
        let titleWidth = min(title.textWidth, available * 0.65)
        title.frame = NSRect(x: 96, y: 10, width: max(titleWidth, 0), height: 16)
        host.frame = NSRect(x: 96 + titleWidth + 8, y: 10, width: max(available - titleWidth - 8, 0), height: 16)
        container.frame = NSRect(x: 6, y: 36, width: max(bounds.width - 12, 0), height: max(bounds.height - 42, 0))
    }
}
