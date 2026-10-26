import AppKit
import SecurityInterface

@MainActor
final class SiteInfoViewController: NSViewController {
    private struct Permission {
        let kind: MBSitePermission
        let title: String
        let symbol: String
        var choices: [MBPermissionState] { kind == .popups ? [.allow, .block] : [.ask, .allow, .block] }
        var standard: MBPermissionState { kind == .popups ? .allow : .ask }
    }

    private static let permissions = [
        Permission(kind: .camera, title: "Camera", symbol: "camera"),
        Permission(kind: .microphone, title: "Microphone", symbol: "mic"),
        Permission(kind: .location, title: "Location", symbol: "location"),
        Permission(kind: .notifications, title: "Notifications", symbol: "bell"),
        Permission(kind: .popups, title: "Pop-ups and Redirects", symbol: "macwindow.on.rectangle"),
    ]

    private static let width: CGFloat = 320
    private static let inset: CGFloat = 16
    private static var contentWidth: CGFloat { width - inset * 2 }

    private let page: MBWebView
    private let tab: TabInfo
    private let store: BrowserStore
    private let close: () -> Void
    private let stack = NSStackView()
    private var pickers: [(Permission, NSPopUpButton)] = []
    private let reset = NSButton(title: "Reset Permissions", target: nil, action: nil)

    init(page: MBWebView, tab: TabInfo, store: BrowserStore, close: @escaping () -> Void) {
        self.page = page
        self.tab = tab
        self.store = store
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: Self.inset, bottom: 14, right: Self.inset)
        let security = page.security
        add(header())
        add(connection(security))
        if let certificate = page.certificate { add(certificateDetails(certificate), spacing: 12) }
        add(separator())
        add(Label.make("Permissions", size: 11, weight: .semibold, color: .secondaryLabelColor), spacing: 6)
        for permission in Self.permissions { add(row(for: permission), spacing: 6) }
        reset.bezelStyle = .accessoryBarAction
        reset.controlSize = .small
        reset.font = Theme.font(11, .medium)
        reset.onAction { [weak self] in self?.resetPermissions() }
        add(reset, fullWidth: false)
        add(separator())
        add(siteData())
        view = stack
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        updateReset()
        preferredContentSize = stack.fittingSize
    }

    private func add(_ view: NSView, spacing: CGFloat = 10, fullWidth: Bool = true) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacing, after: last) }
        stack.addArrangedSubview(view)
        if fullWidth { view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true }
    }

    private func header() -> NSView {
        let icon = NSImageView(image: FaviconCache.shared.image(for: tab))
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let host = Label.make(URL(string: tab.url)?.host() ?? tab.host, size: 13, weight: .semibold)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, host])
        row.spacing = 8
        return row
    }

    private func connection(_ security: MBConnectionSecurity) -> NSView {
        let style = SiteSecurityStyle(security)
        let icon = NSImageView(image: .symbol(style.symbol, size: 13, weight: .medium) ?? NSImage())
        icon.contentTintColor = security == .broken ? .systemRed : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = Label.make(style.title, size: 12.5, weight: .medium)
        let explanation = Label.wrapping(page.securityProblem ?? Self.secureExplanation, size: 11.5)
        explanation.preferredMaxLayoutWidth = Self.contentWidth - 26
        let text = NSStackView(views: [title, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private static let secureExplanation =
        "Information you send to this site, like passwords or card numbers, stays private between you and the site."

    private func certificateDetails(_ certificate: MBCertificate) -> NSView {
        let subject = certificate.organization.isEmpty
            ? certificate.subject : "\(certificate.subject) (\(certificate.organization))"
        var lines = [("Issued to", subject), ("Issued by", certificate.issuer)]
        if let until = certificate.validUntil {
            lines.append(("Valid until", until.formatted(date: .long, time: .omitted)))
        }
        let grid = NSGridView(views: lines.map { name, value in
            let value = Label.make(value, size: 11.5)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [Label.make(name, size: 11.5, color: .secondaryLabelColor), value]
        })
        grid.rowSpacing = 3
        grid.columnSpacing = 8
        grid.xPlacement = .leading
        let show = NSButton(title: "Show Certificate", target: nil, action: nil)
        show.bezelStyle = .accessoryBarAction
        show.controlSize = .small
        show.font = Theme.font(11, .medium)
        show.onAction { [weak self] in self?.showCertificate(certificate) }
        let column = NSStackView(views: [grid, show])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 0, left: 26, bottom: 0, right: 0)
        return column
    }

    private func showCertificate(_ certificate: MBCertificate) {
        let certificates = certificate.chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, let window = page.window ?? store.window else { return }
        close()
        SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                               certificates: certificates, showGroup: true)
    }

    private func row(for permission: Permission) -> NSView {
        let icon = NSImageView(image: .symbol(permission.symbol, size: 12, weight: .regular) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = Label.make(permission.title, size: 12.5)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .small
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.font = Theme.font(11)
        for choice in permission.choices {
            picker.addItem(withTitle: Self.title(of: choice))
            picker.lastItem?.tag = choice.rawValue
        }
        picker.setAccessibilityLabel(permission.title)
        picker.onAction { [weak self, weak picker] in
            guard let self, let tag = picker?.selectedTag(), let state = MBPermissionState(rawValue: tag) else { return }
            page.setState(state, for: permission.kind)
            updateReset()
        }
        pickers.append((permission, picker))
        select(permission, in: picker)
        let row = NSStackView(views: [icon, title, picker])
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    private static func title(of state: MBPermissionState) -> String {
        switch state {
        case .allow: "Allow"
        case .block: "Block"
        default: "Ask"
        }
    }

    private func state(of permission: Permission) -> MBPermissionState {
        let state = page.state(for: permission.kind)
        return permission.choices.contains(state) ? state : permission.standard
    }

    private func select(_ permission: Permission, in picker: NSPopUpButton) {
        picker.selectItem(withTag: state(of: permission).rawValue)
    }

    private func updateReset() {
        reset.isEnabled = pickers.contains { permission, _ in state(of: permission) != permission.standard }
    }

    private func resetPermissions() {
        page.resetPermissions()
        for (permission, picker) in pickers { select(permission, in: picker) }
        updateReset()
    }

    private func siteData() -> NSView {
        let icon = NSImageView(image: .symbol("internaldrive", size: 12, weight: .regular) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = Label.make("Cookies and site data", size: 12.5)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let clear = NSButton(title: "Clear", target: nil, action: nil)
        clear.bezelStyle = .accessoryBarAction
        clear.controlSize = .small
        clear.setContentHuggingPriority(.required, for: .horizontal)
        clear.font = Theme.font(11, .medium)
        clear.toolTip = "Delete this site's cookies and stored data, then reload the page"
        clear.onAction { [weak self] in
            guard let self else { return }
            close()
            store.clearSiteData()
        }
        let row = NSStackView(views: [icon, title, clear])
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}
