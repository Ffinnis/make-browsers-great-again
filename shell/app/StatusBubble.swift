import AppKit

@MainActor
final class StatusBubble: NSView {
    private static let all = NSMapTable<BrowserStore, StatusBubble>.weakToStrongObjects()
    private let label = Label.make(size: 11.5, color: .secondaryLabelColor)
    private let fill = FillLayer()
    private unowned let container: WebContainerView
    private weak var source: MBWebView?

    static func of(_ store: BrowserStore) -> StatusBubble {
        if let bubble = all.object(forKey: store) { return bubble }
        let bubble = StatusBubble(container: store.webContainer)
        all.setObject(bubble, forKey: store)
        store.observe(bubble) { [weak bubble, weak store] _ in
            guard let bubble, !bubble.isHidden, bubble.source !== store?.visibleView else { return }
            bubble.isHidden = true
        }
        return bubble
    }

    private init(container: WebContainerView) {
        self.container = container
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, from view: MBWebView) {
        source = view
        guard !text.isEmpty, let card = container.superview else {
            isHidden = true
            return
        }
        if superview !== card { card.addSubview(self) }
        label.stringValue = text
        place()
        isHidden = false
    }

    private func place() {
        guard let card = superview else { return }
        let page = container.pageArea
        let area = page.width > 0 ? page : card.bounds
        let width = min(label.textWidth + 16, area.width * 0.6)
        frame = NSRect(x: area.minX + 6, y: card.bounds.height - area.maxY + 6, width: max(width, 0), height: 22)
        needsLayout = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        if !isHidden { place() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        label.frame = bounds.insetBy(dx: 8, dy: 3)
        CATransaction.commit()
    }

    override func updateLayer() {
        fill.paint(fill: Theme.toastFill, border: Theme.faint(0.1), in: effectiveAppearance)
        fill.borderWidth = 0.5
    }
}

extension BrowserStore {
    nonisolated func webView(_ view: MBWebView, didChangeStatus status: String) {
        MainActor.assumeIsolated {
            StatusBubble.of(self).show(view === visibleView ? status : "", from: view)
        }
    }
}
