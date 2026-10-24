import AppKit

@MainActor
enum ExtensionPins {
    static let defaultsKey = "ExtensionPins"
    static let limit = 3
    static let fullMessage = "The toolbar holds \(limit) extensions. Unpin one first."

    static func pinned(in profile: String, among items: [InstalledExtension]) -> [String] {
        let usable = Set(items.filter { $0.enabled && $0.hasAction }.map(\.id))
        if let ids = saved[profile] { return ids.filter(usable.contains) }
        let ids = Array(items.filter { usable.contains($0.id) }.prefix(limit).map(\.id))
        if !ids.isEmpty { save(ids, in: profile) }
        return ids
    }

    @discardableResult
    static func toggle(_ id: String, in profile: String, among items: [InstalledExtension]) -> Bool {
        var ids = pinned(in: profile, among: items)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else if ids.count < limit {
            ids.append(id)
        } else {
            return false
        }
        save(ids, in: profile)
        BrowserStore.extensionsChanged()
        return true
    }

    private static var saved: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    private static func save(_ ids: [String], in profile: String) {
        var all = saved
        all[profile] = ids
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}

@MainActor
extension CommandAction {
    static func extensionActions(for store: BrowserStore) -> [Self] {
        let host = store.extensions
        let profile = host.profilePath(store.activeSpace.profileId)
        let all = host.extensions(in: profile)
        let pins = ExtensionPins.pinned(in: profile, among: all)
        var list: [Self] = []
        for item in all where item.enabled {
            let key = ExtensionHost.Key(profile: profile, extensionID: item.id)
            let image = item.icon(size: 16)
            let keywords = ["extension", "add-on"]
            if item.hasAction {
                if store.visibleTab != nil {
                    list.append(Self(id: "extension-\(item.id)", title: item.name, symbol: "puzzlepiece.extension",
                                     keywords: keywords, image: image) { store.runExtensionAction(key, from: nil) })
                }
                let pinned = pins.contains(item.id)
                list.append(Self(id: "extension-pin-\(item.id)", title: pinned ? "Unpin \(item.name)" : "Pin \(item.name) to Toolbar",
                                 symbol: pinned ? "pin.slash" : "pin", keywords: keywords + ["toolbar"], image: image) {
                        if !ExtensionPins.toggle(item.id, in: profile, among: all) {
                            store.showToast(Toast(message: ExtensionPins.fullMessage, symbol: "pin"))
                        }
                    })
            }
            if item.optionsPage != nil {
                list.append(Self(id: "extension-options-\(item.id)", title: "\(item.name) Options", symbol: "gearshape",
                                 keywords: keywords + ["settings", "preferences"], image: image) { host.openOptions(key) })
            }
        }
        return list
    }
}

@MainActor
final class ExtensionButtonsView: FlippedView {
    private let store: BrowserStore
    private var buttons: [ExtensionButton] = []
    private let more: SymbolButton
    private let dot = NSView()
    private var items: [InstalledExtension] = []

    init(store: BrowserStore) {
        self.store = store
        more = SymbolButton("puzzlepiece.extension", size: 12)
        super.init(frame: .zero)
        more.toolTip = "Extensions"
        more.action = { [weak self] in self?.showList() }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        more.addSubview(dot)
        addSubview(more)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let host = store.extensions
        let profile = host.profilePath(store.activeSpace.profileId)
        let all = host.extensions(in: profile)
        let pins = ExtensionPins.pinned(in: profile, among: all)
        items = pins.compactMap { id in all.first { $0.id == id } }
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
            button.menu = Self.menu(for: item, key: key, store: store)
        }
        dot.isHidden = !all.contains { item in
            guard item.enabled, item.hasAction, !pins.contains(item.id) else { return false }
            let key = ExtensionHost.Key(profile: profile, extensionID: item.id)
            return !(host.action(key, tab: tab).badgeText ?? "").isEmpty
        }
        more.isHidden = all.isEmpty
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
        dot.frame = NSRect(x: 17, y: 4, width: 6, height: 6)
        for button in buttons {
            x -= 26
            button.isHidden = x < 0
            button.frame = NSRect(x: x, y: 3, width: 26, height: 24)
        }
    }

    private func showList() {
        let popover = NSPopover()
        popover.behavior = .transient
        let list = ExtensionListView(store: store) { [weak popover] in popover?.close() }
        let controller = NSViewController()
        controller.view = list
        popover.contentViewController = controller
        popover.contentSize = list.frame.size
        popover.show(relativeTo: more.bounds, of: more, preferredEdge: .maxY)
    }

    static func menu(for item: InstalledExtension, key: ExtensionHost.Key, store: BrowserStore) -> NSMenu {
        let menu = NSMenu()
        menu.add(item.name, enabled: false) {}
        for entry in store.extensions.actionMenuItems(key) {
            menu.add(entry.title, state: entry.checked) { [weak store] in
                guard let store, let tab = store.visibleTabID else { return }
                store.extensions.choosePageMenuItem(entry.id, context: ["pageUrl": store.visibleTab?.url ?? ""],
                                                    profile: key.profile, tab: tab)
            }
        }
        menu.addItem(.separator())
        if item.enabled, item.hasAction {
            let all = store.extensions.extensions(in: key.profile)
            let pinned = ExtensionPins.pinned(in: key.profile, among: all).contains(item.id)
            menu.add(pinned ? "Unpin from Toolbar" : "Pin to Toolbar") { [weak store] in
                if !ExtensionPins.toggle(item.id, in: key.profile, among: all) {
                    store?.showToast(Toast(message: ExtensionPins.fullMessage, symbol: "pin"))
                }
            }
        }
        if item.optionsPage != nil {
            menu.add("Options") { [weak store] in store?.extensions.openOptions(key) }
        }
        menu.add("Manage Extensions…") { [weak store] in
            store?.showExtensions(url: "chrome://extensions/?id=\(item.id)")
        }
        return menu
    }
}

private final class ExtensionListView: FlippedView {
    private let store: BrowserStore
    private let dismiss: () -> Void

    init(store: BrowserStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
        super.init(frame: .zero)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        let host = store.extensions
        let profile = host.profilePath(store.activeSpace.profileId)
        let all = host.extensions(in: profile)
        let pins = ExtensionPins.pinned(in: profile, among: all)
        let tab = store.visibleTabID.flatMap { host.extensionTabID(of: $0) }
        let width: CGFloat = 250
        var y: CGFloat = 6
        for item in all {
            let key = ExtensionHost.Key(profile: profile, extensionID: item.id)
            let usable = item.enabled && item.hasAction
            let pinned = pins.contains(item.id)
            let row = ExtensionListRow(item, badge: usable ? host.action(key, tab: tab).badgeText : nil)
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: 28)
            row.menu = ExtensionButtonsView.menu(for: item, key: key, store: store)
            if usable {
                row.action = { [weak self] in
                    guard let self else { return }
                    dismiss()
                    store.runExtensionAction(key, from: nil)
                }
                row.showPin(pinned, canPin: pinned || pins.count < ExtensionPins.limit) { [weak self] in
                    ExtensionPins.toggle(item.id, in: profile, among: all)
                    self?.reload()
                }
            }
            addSubview(row)
            y += 28
        }
        if !all.isEmpty {
            let rule = NSView(frame: NSRect(x: 12, y: y + 4, width: width - 24, height: 1))
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Theme.faint(0.1).cgColor
            addSubview(rule)
            y += 9
        }
        let manage = ExtensionListRow(title: "Manage Extensions…")
        manage.frame = NSRect(x: 6, y: y, width: width - 12, height: 28)
        manage.action = { [weak self] in
            guard let self else { return }
            dismiss()
            store.showExtensions()
        }
        addSubview(manage)
        setFrameSize(NSSize(width: width, height: y + 28 + 6))
    }
}

private final class ExtensionListRow: HoverView {
    var action: (() -> Void)?
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let name: NSTextField
    private let badge = Label.chip()
    private var pin: SymbolButton?

    init(_ item: InstalledExtension, badge text: String?) {
        name = Label.make(item.name)
        super.init(frame: .zero)
        icon.image = item.icon(size: 16)
        setUp()
        if !(item.enabled && item.hasAction) {
            icon.alphaValue = 0.4
            name.textColor = .tertiaryLabelColor
        }
        badge.stringValue = text ?? ""
        badge.isHidden = (text ?? "").isEmpty
    }

    init(title: String) {
        name = Label.make(title, color: .secondaryLabelColor)
        super.init(frame: .zero)
        setUp()
        badge.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUp() {
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, name, badge] as [NSView] { addSubview(view) }
    }

    func showPin(_ pinned: Bool, canPin: Bool, toggle: @escaping () -> Void) {
        let button = SymbolButton(pinned ? "pin.fill" : "pin", size: 11, action: toggle)
        button.toolTip = pinned ? "Unpin from Toolbar" : canPin ? "Pin to Toolbar" : ExtensionPins.fullMessage
        button.isEnabled = canPin
        addSubview(button)
        pin = button
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let midY = bounds.midY
        var right = bounds.width - 2
        if let pin {
            pin.frame = NSRect(x: right - 26, y: midY - 11, width: 26, height: 22)
            right = pin.frame.minX - 2
        }
        if !badge.isHidden {
            let width = badge.textWidth + 8
            badge.frame = NSRect(x: right - width, y: midY - 8, width: width, height: 16)
            right = badge.frame.minX - 6
        }
        let x: CGFloat = icon.image == nil ? 8 : 34
        icon.frame = NSRect(x: 8, y: midY - 8, width: 16, height: 16)
        name.frame = NSRect(x: x, y: midY - 8, width: max(right - x, 0), height: 16)
    }

    override func updateLayer() {
        fill.paint(fill: hovering && action != nil ? Theme.hoverFill : nil, in: effectiveAppearance)
        badge.layer?.backgroundColor = Theme.faint(0.08).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func mouseDown(with event: NSEvent) {}
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
    nonisolated func webView(_ view: MBWebView, didReceiveFormMessage message: String, url: String) {}
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
