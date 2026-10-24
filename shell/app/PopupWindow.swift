import AppKit

@MainActor
final class PopupWindow: NSObject, NSWindowDelegate, MBWebViewDelegate {
    private static var open: Set<PopupWindow> = []
    let window: NSWindow
    private let view: MBWebView
    private weak var opener: MBWebView?
    private weak var store: BrowserStore?
    private let color: RGB
    private let content: PopupWindowView
    private var url = ""
    private var closing = false

    static let defaultSize = NSSize(width: 500, height: 640)

    init(view: MBWebView, opener: MBWebView, store: BrowserStore, color: RGB, size: NSSize) {
        self.view = view
        self.opener = opener
        self.store = store
        self.color = color
        let page = NSSize(width: size.width > 0 ? max(size.width, 320) : Self.defaultSize.width,
                          height: size.height > 0 ? max(size.height, 240) : Self.defaultSize.height)
        let frame = PopupWindowView.frame(around: page)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: frame),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 280)
        window.acceptsMouseMovedEvents = true
        content = PopupWindowView(color: color)
        super.init()
        window.delegate = self
        window.contentView = content
        content.copyLink = { [weak self] in self?.copyLink() }
        content.host(view, cornerRadius: max(window.systemCornerRadius - 6, 6))
        view.delegate = self
        place(over: opener.window)
        Self.open.insert(self)
    }

    func show() {
        guard !Motion.reduced else {
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

    private func copyLink() {
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        content.showCopied()
    }

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

    func windowWillClose(_ notification: Notification) {
        closing = true
        if view.isClosing, view.browserIdentifier == 0 {
            Self.open.remove(self)
        } else {
            view.close()
        }
        opener?.window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        view.focusContent()
    }

    private func place(over parent: NSWindow?) {
        let size = window.frame.size
        guard let screen = parent?.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let area = screen.visibleFrame
        let anchor = parent?.frame ?? area
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let x = min(max(anchor.midX - width / 2, area.minX), area.maxX - width)
        let y = min(max(anchor.midY - height / 2 + anchor.height * 0.05, area.minY), area.maxY - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    nonisolated func webViewDidClose(_ view: MBWebView) {
        MainActor.assumeIsolated {
            if window.isVisible {
                fadeOutAndClose()
            } else {
                Self.open.remove(self)
            }
        }
    }

    nonisolated func webViewRendererDidTerminate(_ view: MBWebView) {
        MainActor.assumeIsolated { fadeOutAndClose() }
    }

    nonisolated func webView(_ view: MBWebView, didChangeURL url: String) {
        MainActor.assumeIsolated {
            self.url = url
            content.setURL(url)
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeTitle title: String) {
        MainActor.assumeIsolated {
            window.title = title
            content.setTitle(title)
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        MainActor.assumeIsolated { content.setLoading(loading) }
    }

    nonisolated func webView(_ view: MBWebView, didReceiveFavicon png: Data) {
        MainActor.assumeIsolated { content.setIcon(NSImage(data: png)) }
    }

    nonisolated func webView(_ view: MBWebView, requestsNewTabWithURL url: String, foreground: Bool) {
        MainActor.assumeIsolated {
            if let store, let opener {
                store.webView(opener, requestsNewTabWithURL: url, foreground: foreground)
            } else {
                store?.openFromSystem(url)
            }
        }
    }

    nonisolated func webView(_ view: MBWebView, hostsPopup popup: MBWebView, size: NSSize) -> Bool {
        MainActor.assumeIsolated {
            guard let store else { return false }
            PopupWindow(view: popup, opener: view, store: store, color: color, size: size).show()
            return true
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeBusy busy: Bool) {}
    nonisolated func webView(_ view: MBWebView, didChangeFullscreen fullscreen: Bool) {}
    nonisolated func webView(_ view: MBWebView, didChangeThemeColor color: String) {}
    nonisolated func webView(_ view: MBWebView, didChangeBlockedCount count: UInt) {}
    nonisolated func webView(_ view: MBWebView, didChangeConsoleErrors errors: UInt, warnings: UInt) {}
    nonisolated func webView(_ view: MBWebView, didFinishLoadWithStatus status: Int32, duration: TimeInterval) {}
    nonisolated func webView(_ view: MBWebView, opensExtensionsPage url: String, fromPage page: String) {}
    nonisolated func webViewDidStopPicking(_ view: MBWebView) {}
    nonisolated func webViewDidChangeDevTools(_ view: MBWebView) {}
    nonisolated func webView(_ view: MBWebView, didLogConsoleMessage message: String, level: Int, source: String, line: Int32) {}
    nonisolated func webView(_ view: MBWebView, didObserveNetworkEvent method: String, params: [AnyHashable: Any]) {}
    nonisolated func webView(_ view: MBWebView, didReceiveDevToolsEvent method: String, params: [AnyHashable: Any]) {}
    nonisolated func webView(_ view: MBWebView, didPickNode backendNodeId: Int) {}
    nonisolated func webView(_ view: MBWebView, inspectsElementAt point: NSPoint) {}
    nonisolated func webView(_ view: MBWebView, didReceiveFormMessage message: String, url: String) {}
}

extension BrowserStore {
    @objc(webView:hostsPopup:size:)
    nonisolated func webView(_ view: MBWebView, hostsPopup popup: MBWebView, size: NSSize) -> Bool {
        MainActor.assumeIsolated {
            guard views[view.tabID] === view else { return false }
            let space = snapshot.spaces.first { s in
                s.today.contains { $0.id == view.tabID } || s.pinned.contains { $0.id == view.tabID }
                    || s.favorites.contains { $0.id == view.tabID }
            }
            PopupWindow(view: popup, opener: view, store: self, color: RGB(space?.color ?? Theme.spaceColors[0]),
                        size: size).show()
            return true
        }
    }
}

private final class PopupWindowView: FlippedView {
    private static let barHeight: CGFloat = 36
    private static let inset: CGFloat = 6
    private let color: RGB
    private let backdrop = BackdropView()
    private let bar = WindowDragView()
    private let icon = NSImageView()
    private let lock = NSImageView()
    private let address = Label.make(size: 12.5, weight: .medium)
    private let title = Label.make(size: 12, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let copy = NSButton()
    private let container = NSView()
    private var secure = false
    var copyLink: (() -> Void)?

    static func frame(around page: NSSize) -> NSSize {
        NSSize(width: page.width + inset * 2, height: page.height + barHeight + inset)
    }

    init(color: RGB) {
        self.color = color
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = .symbol("globe", size: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        lock.image = .symbol("lock.fill", size: 10, weight: .regular)
        lock.contentTintColor = .labelColor
        lock.alphaValue = 0.5
        lock.isHidden = true
        address.lineBreakMode = .byTruncatingHead
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        copy.isBordered = false
        copy.image = .symbol("link", size: 12)
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = "Copy link"
        copy.onAction { [weak self] in self?.copyLink?() }
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(backdrop)
        addSubview(bar)
        for view in [icon, lock, address, title, spinner, copy] as [NSView] { bar.addSubview(view) }
        addSubview(container)
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func host(_ view: NSView, cornerRadius: CGFloat) {
        container.layer?.cornerRadius = cornerRadius
        layoutSubtreeIfNeeded()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    func setURL(_ url: String) {
        let components = URLComponents(string: url)
        secure = components?.scheme == "https"
        lock.isHidden = !secure
        let host = components?.host ?? url
        address.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        needsLayout = true
    }

    func setTitle(_ text: String) {
        title.stringValue = text
        needsLayout = true
    }

    func setIcon(_ image: NSImage?) {
        guard let image else { return }
        icon.image = image
        icon.contentTintColor = nil
    }

    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func showCopied() {
        copy.image = .symbol("checkmark", size: 12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copy.image = .symbol("link", size: 12)
        }
    }

    private func updateTint() {
        let stops = Theme.gradient(for: color, dark: effectiveAppearance.isDark, active: true, style: TintStyle.saved)
        backdrop.setColors(stops.map(\.cgColor), curve: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        backdrop.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        icon.frame = NSRect(x: 74, y: 11, width: 14, height: 14)
        copy.frame = NSRect(x: bounds.width - 10 - 24, y: 6, width: 24, height: 24)
        spinner.frame = NSRect(x: copy.frame.minX - 18, y: 10, width: 16, height: 16)
        var x: CGFloat = 96
        if secure {
            lock.frame = NSRect(x: x, y: 12, width: 10, height: 12)
            x += 14
        }
        let available = max(spinner.frame.minX - 6 - x, 0)
        let addressWidth = min(address.textWidth, available)
        address.frame = NSRect(x: x, y: 10, width: addressWidth, height: 16)
        let titleX = x + addressWidth + 8
        title.frame = NSRect(x: titleX, y: 10, width: max(available - addressWidth - 8, 0), height: 16)
        container.frame = NSRect(x: inset, y: Self.barHeight, width: max(bounds.width - inset * 2, 0),
                                 height: max(bounds.height - Self.barHeight - inset, 0))
    }
}
