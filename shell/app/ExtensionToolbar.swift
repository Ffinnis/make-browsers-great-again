import AppKit

@MainActor
final class ExtensionButtonsView: FlippedView {
    private let store: BrowserStore
    private var buttons: [ExtensionButton] = []
    private let more: SymbolButton
    private var items: [InstalledExtension] = []

    init(store: BrowserStore) {
        self.store = store
        more = SymbolButton("puzzlepiece.extension", size: 12)
        super.init(frame: .zero)
        more.toolTip = "Extensions"
        more.action = { [weak self] in self?.showMenu() }
        addSubview(more)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let host = store.extensions
        let profile = host.profilePath(store.activeSpace.profileId)
        items = host.extensions(in: profile).filter { $0.enabled && $0.hasAction }
        let tab = store.visibleTabID.flatMap { host.extensionTabID(of: $0) }
        while buttons.count > items.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < items.count {
            let button = ExtensionButton()
            addSubview(button)
            buttons.append(button)
        }
        for (button, item) in zip(buttons, items) {
            let key = ExtensionHost.Key(profile: profile, extensionID: item.id)
            button.show(item, state: host.action(key, tab: tab))
            button.action = { [weak self, weak button] in
                guard let self, let button else { return }
                store.runExtensionAction(key, from: button)
            }
            button.menu = buttonMenu(item, key: key)
        }
        more.isHidden = host.extensions(in: profile).isEmpty
        needsLayout = true
    }

    func anchor(for extensionID: String) -> NSView {
        let index = items.firstIndex { $0.id == extensionID }
        return index.map { buttons[$0] }.flatMap { $0.isHidden ? nil : $0 } ?? more
    }

    var preferredWidth: CGFloat {
        more.isHidden ? 0 : CGFloat(items.count + 1) * 26
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 26
        more.frame = NSRect(x: x, y: 3, width: 26, height: 24)
        for button in buttons {
            x -= 26
            button.isHidden = x < 0
            button.frame = NSRect(x: x, y: 3, width: 26, height: 24)
        }
    }

    private func showMenu() {
        let host = store.extensions
        let profile = host.profilePath(store.activeSpace.profileId)
        let menu = NSMenu()
        for item in host.extensions(in: profile) {
            let key = ExtensionHost.Key(profile: profile, extensionID: item.id)
            let entry = menu.add(item.name, enabled: item.enabled && item.hasAction) { [weak self] in
                guard let self else { return }
                store.runExtensionAction(key, from: more)
            }
            entry.image = item.icon(size: 16)
            entry.submenu = buttonMenu(item, key: key)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.add("Manage Extensions…") { [weak self] in self?.store.showExtensions() }
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 4), in: self)
    }

    private func buttonMenu(_ item: InstalledExtension, key: ExtensionHost.Key) -> NSMenu {
        let menu = NSMenu()
        menu.add(item.name, enabled: false) {}
        for entry in store.extensions.actionMenuItems(key) {
            menu.add(entry.title, state: entry.checked) { [weak self] in
                guard let self, let tab = store.visibleTabID else { return }
                store.extensions.choosePageMenuItem(entry.id, context: ["pageUrl": store.visibleTab?.url ?? ""],
                                                    profile: key.profile, tab: tab)
            }
        }
        menu.addItem(.separator())
        if item.optionsPage != nil {
            menu.add("Options") { [weak self] in self?.store.extensions.openOptions(key) }
        }
        menu.add("Manage Extensions…") { [weak self] in
            self?.store.showExtensions(url: "chrome://extensions/?id=\(item.id)")
        }
        return menu
    }
}

private final class ExtensionButton: HoverView {
    var action: (() -> Void)?
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let badgeFill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.layer?.masksToBounds = true
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ item: InstalledExtension, state: ExtensionHost.ActionState) {
        icon.image = state.icon.flatMap(NSImage.fromDataURL) ?? item.icon(size: 16)
        icon.alphaValue = state.enabled == false ? 0.4 : 1
        toolTip = state.title ?? item.name
        let text = state.badgeText ?? ""
        badge.isHidden = text.isEmpty
        badge.stringValue = text
        badge.layer?.backgroundColor = (state.badgeColor.map(NSColor.init(rgba:)) ?? NSColor(red: 0.37, green: 0.39, blue: 0.41, alpha: 1)).cgColor
        badge.textColor = state.badgeTextColor.map(NSColor.init(rgba:)) ?? .white
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let width = min(max(badge.attributedStringValue.size().width + 4, 12), bounds.width)
        badge.frame = NSRect(x: bounds.width - width, y: bounds.height - 11, width: width, height: 11)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.hoverFill : nil, in: effectiveAppearance)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func mouseDown(with event: NSEvent) {}
}

@MainActor
final class ExtensionPopup: NSObject, NSPopoverDelegate, MBWebViewDelegate {
    private static var shown: ExtensionPopup?
    private let popover = NSPopover()
    private let view: MBWebView
    private weak var store: BrowserStore?

    static func show(url: String, profilePath: String, from anchor: NSView, store: BrowserStore) {
        shown?.popover.close()
        let popup = ExtensionPopup(url: url, profilePath: profilePath, store: store)
        shown = popup
        popup.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private init(url: String, profilePath: String, store: BrowserStore) {
        self.store = store
        view = MBWebView(url: url, profilePath: profilePath, tabID: 0)
        super.init()
        view.delegate = self
        store.extensions.registerPopup(view)
        let controller = NSViewController()
        view.frame = NSRect(x: 0, y: 0, width: 25, height: 25)
        controller.view = view
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func popoverDidShow(_ notification: Notification) {
        view.focusContent()
    }

    func popoverDidClose(_ notification: Notification) {
        view.close()
        if Self.shown === self { Self.shown = nil }
    }

    private static let sizeScript = """
    (() => {
      const measure = () => {
        const root = document.documentElement, body = document.body;
        const width = root.style.width;
        root.style.width = 'min-content';
        const w = Math.ceil(root.getBoundingClientRect().width);
        root.style.width = width;
        // The body's extent: the page's scroll height never drops below
        // the popup's, so it couldn't shrink.
        const h = body
          ? Math.ceil(body.getBoundingClientRect().bottom + parseFloat(getComputedStyle(body).marginBottom || 0) + window.scrollY)
          : root.scrollHeight;
        console.debug('__mbgaPopupSize', w, h);
      };
      const observer = new ResizeObserver(measure);
      observer.observe(document.documentElement);
      if (document.body) { observer.observe(document.body); }
      measure();
    })()
    """

    nonisolated func webView(_ view: MBWebView, didFinishLoadWithStatus status: Int32, duration: TimeInterval) {
        MainActor.assumeIsolated {
            let params = try? JSONSerialization.data(withJSONObject: ["expression": Self.sizeScript])
            view.sendDevToolsCommand("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) }) { _, _ in }
        }
    }

    nonisolated func webView(_ view: MBWebView, didLogConsoleMessage message: String, level: Int, source: String, line: Int32) {
        MainActor.assumeIsolated {
            let parts = message.split(separator: " ")
            guard parts.count == 3, parts[0] == "__mbgaPopupSize", let w = Double(parts[1]), let h = Double(parts[2]) else { return }
            let size = NSSize(width: min(max(w, 25), 800), height: min(max(h, 25), 600))
            guard size != popover.contentSize else { return }
            popover.contentSize = size
        }
    }

    nonisolated func webViewDidClose(_ view: MBWebView) {
        MainActor.assumeIsolated { if popover.isShown { popover.close() } }
    }

    nonisolated func webView(_ view: MBWebView, requestsNewTabWithURL url: String, foreground: Bool) {
        MainActor.assumeIsolated { store?.openFromSystem(url) }
    }

    nonisolated func webView(_ view: MBWebView, didChangeURL url: String) {}
    nonisolated func webView(_ view: MBWebView, didChangeTitle title: String) {}
    nonisolated func webView(_ view: MBWebView, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    nonisolated func webView(_ view: MBWebView, didReceiveFavicon png: Data) {}
    nonisolated func webView(_ view: MBWebView, didChangeBusy busy: Bool) {}
    nonisolated func webView(_ view: MBWebView, didChangeFullscreen fullscreen: Bool) {}
    nonisolated func webViewRendererDidTerminate(_ view: MBWebView) {
        MainActor.assumeIsolated { popover.close() }
    }
    nonisolated func webView(_ view: MBWebView, didChangeThemeColor color: String) {}
    nonisolated func webView(_ view: MBWebView, didChangeBlockedCount count: UInt) {}
    nonisolated func webView(_ view: MBWebView, didChangeConsoleErrors errors: UInt, warnings: UInt) {}
    nonisolated func webViewDidStopPicking(_ view: MBWebView) {}
    nonisolated func webViewDidChangeDevTools(_ view: MBWebView) {}
    nonisolated func webView(_ view: MBWebView, didObserveNetworkEvent method: String, params: [AnyHashable: Any]) {}
    nonisolated func webView(_ view: MBWebView, didReceiveDevToolsEvent method: String, params: [AnyHashable: Any]) {}
    nonisolated func webView(_ view: MBWebView, didPickNode backendNodeId: Int) {}
    nonisolated func webView(_ view: MBWebView, inspectsElementAt point: NSPoint) {}
    nonisolated func webView(_ view: MBWebView, didReceiveFormMessage message: String, url: String, frame: String) {}
    nonisolated func webView(_ view: MBWebView, opensExtensionsPage url: String, fromPage page: String) {
        MainActor.assumeIsolated { store?.showExtensions(url: url) }
    }
}

extension NSImage {
    static func fromDataURL(_ url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ","), url.hasPrefix("data:"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

extension NSColor {
    convenience init(rgba: [Double]) {
        let c = rgba + [255, 255, 255, 255]
        self.init(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c[3] / 255)
    }
}

@MainActor
extension InstalledExtension {
    private static var icons: [URL: NSImage] = [:]

    func icon(size: Int) -> NSImage? {
        if let file = iconFile(size: size) {
            if let known = Self.icons[file] { return known }
            if let image = NSImage(contentsOf: file) {
                Self.icons[file] = image
                return image
            }
        }
        let side = CGFloat(size)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: side / 4, yRadius: side / 4).fill()
            let letter = String(name.prefix(1)).uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.6, weight: .semibold),
                .foregroundColor: NSColor.windowBackgroundColor,
            ]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
    }
}
