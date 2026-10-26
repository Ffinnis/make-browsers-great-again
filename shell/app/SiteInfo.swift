import AppKit

extension Notification.Name {
    static let siteSecurityChanged = Notification.Name("MBGASiteSecurityChanged")
}

struct SiteSecurityStyle {
    let symbol: String
    let tint: NSColor
    let alpha: CGFloat
    let title: String

    init(_ security: MBConnectionSecurity) {
        switch security {
        case .secure:
            (symbol, tint, alpha, title) = ("lock.fill", .labelColor, 0.5, "Connection is secure")
        case .broken:
            (symbol, tint, alpha, title) = ("exclamationmark.triangle.fill", .systemRed, 0.9, "Connection is not secure")
        case .mixed:
            (symbol, tint, alpha, title) = ("lock.slash.fill", .labelColor, 0.6, "Connection is not fully secure")
        default:
            (symbol, tint, alpha, title) = ("lock.slash.fill", .labelColor, 0.6, "Connection is not secure")
        }
    }
}

extension BrowserStore {
    nonisolated func webViewDidChangeSecurity(_ view: MBWebView) {
        MainActor.assumeIsolated {
            guard views[view.tabID] === view else { return }
            NotificationCenter.default.post(name: .siteSecurityChanged, object: view)
        }
    }
}

final class SiteSecurityBadge: HoverView {
    private let store: BrowserStore
    private let imageView = NSImageView()
    private let fill = FillLayer()
    private var shown: MBConnectionSecurity?

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 5
        layer?.addSublayer(fill)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(securityChanged(_:)),
                                               name: .siteSecurityChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func securityChanged(_ notification: Notification) {
        guard notification.object as? MBWebView === store.visibleView else { return }
        update()
        superview?.needsLayout = true
    }

    func update() {
        let security = store.visibleView?.security ?? MBConnectionSecurity.none
        isHidden = security == .none
        guard security != shown else { return }
        shown = security
        let style = SiteSecurityStyle(security)
        imageView.image = .symbol(style.symbol, size: 10, weight: .regular)
        imageView.contentTintColor = style.tint
        imageView.alphaValue = style.alpha
        toolTip = style.title
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        imageView.frame = bounds
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.hoverFill : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.6
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { SiteInfo.toggle(store: store, from: self) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Site Information" }
    override func accessibilityHelp() -> String? { toolTip }

    override func accessibilityPerformPress() -> Bool {
        SiteInfo.toggle(store: store, from: self)
        return true
    }

    var isOnScreen: Bool {
        guard let content = window?.contentView, !isHiddenOrHasHiddenAncestor, visibleRect.width > 0 else { return false }
        return content.bounds.intersects(convert(bounds, to: content))
    }
}

@MainActor
enum SiteInfo {
    private weak static var popover: NSPopover?

    static func canShow(store: BrowserStore?) -> Bool {
        guard let view = store?.visibleView else { return false }
        return view.security != .none
    }

    static func toggle(store: BrowserStore, from badge: SiteSecurityBadge? = nil) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        show(store: store, from: badge)
    }

    static func show(store: BrowserStore, from badge: SiteSecurityBadge? = nil) {
        popover?.close()
        guard let page = store.visibleView, let tab = store.visibleTab, canShow(store: store) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.reduced
        popover.contentViewController = SiteInfoViewController(page: page, tab: tab, store: store) { [weak popover] in
            popover?.close()
        }
        self.popover = popover
        let anchor = badge ?? store.window?.contentView?.firstSubview(of: SiteSecurityBadge.self)
        if let anchor, anchor.isOnScreen {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            popover.show(relativeTo: NSRect(x: 36, y: 10, width: 1, height: 1), of: page, preferredEdge: .maxY)
        }
    }
}

@MainActor
final class SiteInfoCommands: NSObject, NSMenuItemValidation {
    static let shared = SiteInfoCommands()

    @objc func showSiteInformation(_ sender: Any?) {
        if let store = BrowserStore.front { SiteInfo.show(store: store) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        SiteInfo.canShow(store: BrowserStore.front)
    }
}
