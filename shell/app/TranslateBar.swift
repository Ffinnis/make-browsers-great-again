import AppKit

@MainActor
final class TranslateBarView: HoverView {
    private static let height: CGFloat = 36

    private unowned let translator: PageTranslator
    private unowned let container: WebContainerView
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let message = Label.make(size: 13, weight: .medium)
    private let action = NSButton()
    private lazy var close = SymbolButton("xmark", size: 10) { [weak self] in self?.dismiss() }
    private var hideTimer: Timer?
    private(set) var state: TranslationState?

    init(translator: PageTranslator, container: WebContainerView) {
        self.translator = translator
        self.container = container
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        isHidden = true
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        icon.image = .symbol("translate", size: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        action.isBordered = false
        action.onAction { [weak self] in self?.perform() }
        for view in [icon, message, action, close] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ state: TranslationState) {
        self.state = state
        let name = state.language?.name
        switch state.phase {
        case .offered:
            message.stringValue = name.map { "This page is in \($0)" } ?? "Translate this page?"
            setAction(state.language?.onDevice == true ? "Translate" : "Translate with Google")
        case .translating:
            message.stringValue = name.map { "Translating from \($0)…" } ?? "Translating…"
            setAction("Show Original")
        case .translated:
            message.stringValue = name.map { "Translated from \($0)" } ?? "Translated"
            setAction("Show Original")
        case .proxied:
            message.stringValue = "Translated by Google"
            setAction("Show Original")
        }
        place()
        needsLayout = true
        setVisible(true, animated: true)
        scheduleHide(after: state.phase == .offered ? 15 : state.phase == .translating ? nil : 5)
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        state = nil
        setVisible(false, animated: true)
    }

    private func setAction(_ title: String) {
        action.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.font(13, .semibold), .foregroundColor: NSColor.controlAccentColor,
        ])
    }

    private func perform() {
        guard let state else { return }
        if state.phase == .offered {
            translator.translateVisible()
        } else {
            translator.showOriginalVisible()
        }
    }

    private func dismiss() {
        if state?.phase == .offered { translator.dismissOffer() } else { hide() }
    }

    private func scheduleHide(after seconds: TimeInterval?) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let seconds else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovering { self.scheduleHide(after: 3) } else { self.hide() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private var preferredWidth: CGFloat {
        12 + 16 + 8 + message.textWidth + 12 + action.attributedTitle.size().width + 12 + 4 + 24 + 6
    }

    func place() {
        guard let card = superview else { return }
        let page = container.pageArea
        let area = page.width > 0 ? page : card.bounds
        let width = min(ceil(preferredWidth), area.width - 24)
        frame = NSRect(x: max(area.maxX - width - 12, area.minX), y: card.bounds.height - area.minY - 12 - Self.height,
                       width: width, height: Self.height)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        place()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        let mid = bounds.midY
        icon.frame = NSRect(x: 12, y: mid - 8, width: 16, height: 16)
        close.frame = NSRect(x: bounds.width - 6 - 24, y: mid - 12, width: 24, height: 24)
        let actionWidth = ceil(action.attributedTitle.size().width) + 4
        action.frame = NSRect(x: close.frame.minX - 4 - actionWidth, y: mid - 9, width: actionWidth, height: 18)
        message.frame = NSRect(x: 36, y: mid - 8, width: max(action.frame.minX - 12 - 36, 0), height: 16)
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        fill.paint(fill: Theme.toastFill, border: Theme.faint(0.1), in: effectiveAppearance)
        fill.borderWidth = 0.5
        fill.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.14).cgColor
        fill.shadowOpacity = 1
        fill.shadowRadius = 10
        fill.shadowOffset = CGSize(width: 0, height: -3)
    }
}
