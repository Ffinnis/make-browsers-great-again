import AppKit

struct FindState: Equatable {
    let tabID: UInt64
    var query: String
    var matches = 0
    var active = 0
}

@MainActor
final class PageFinder {
    private unowned let store: BrowserStore
    private(set) var state: FindState? {
        didSet { if state != oldValue, let state { bar.update(state) } }
    }
    private var lastQuery = ""
    private lazy var bar = FindBarView(finder: self, container: store.webContainer)

    private static let all = NSMapTable<BrowserStore, PageFinder>.weakToStrongObjects()

    static func of(_ store: BrowserStore) -> PageFinder {
        if let finder = all.object(forKey: store) { return finder }
        let finder = PageFinder(store: store)
        all.setObject(finder, forKey: store)
        return finder
    }

    private init(store: BrowserStore) {
        self.store = store
        store.observe(self) { [weak self] _ in
            guard let self, let state, state.tabID != store.visibleTabID else { return }
            close(focusingPage: false)
        }
    }

    func show() {
        guard let id = store.visibleTabID, store.views[id] != nil,
              let card = store.webContainer.superview else { return }
        if bar.superview !== card { card.addSubview(bar) }
        if state?.tabID != id {
            state = FindState(tabID: id, query: lastQuery)
            if !lastQuery.isEmpty { search(lastQuery) }
        }
        bar.place()
        bar.setVisible(true, animated: true)
        bar.focus()
    }

    func search(_ query: String) {
        guard var state else { return }
        state.query = query
        if query.isEmpty {
            state.matches = 0
            state.active = 0
        }
        self.state = state
        lastQuery = query
        guard let view = store.views[state.tabID] else { return }
        if query.isEmpty {
            view.stopFinding(true)
        } else {
            view.findText(query, forward: true, next: true)
        }
    }

    func next(forward: Bool) {
        guard let state, state.tabID == store.visibleTabID else {
            show()
            return
        }
        guard !state.query.isEmpty, let view = store.views[state.tabID] else { return }
        view.findText(state.query, forward: forward, next: true)
    }

    func useSelection() {
        guard let id = store.visibleTabID, let view = store.views[id] else { return }
        let params = #"{"expression":"String(getSelection())","returnByValue":true}"#
        view.sendDevToolsCommand("Runtime.evaluate", params: params) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let text = Self.stringValue(of: result), !text.isEmpty else { return }
                let pasteboard = NSPasteboard(name: .find)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.lastQuery = text
                self.show()
                self.search(text)
            }
        }
    }

    private static func stringValue(of result: String?) -> String? {
        guard let data = result?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (json["result"] as? [String: Any])?["value"] as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close(focusingPage: Bool = true) {
        guard let state else { return }
        let view = store.views[state.tabID]
        view?.stopFinding(false)
        self.state = nil
        bar.setVisible(false, animated: true)
        if focusingPage { view?.focusContent() }
    }

    func found(in view: MBWebView, count: Int, active: Int) {
        guard let state, state.tabID == view.tabID, !state.query.isEmpty,
              store.views[view.tabID] === view else { return }
        self.state?.matches = count
        if active > 0 || count == 0 { self.state?.active = active }
    }
}

extension BrowserStore {
    var finder: PageFinder { PageFinder.of(self) }

    nonisolated func webView(_ view: MBWebView, didFindMatches count: Int, active: Int, finished: Bool) {
        MainActor.assumeIsolated { finder.found(in: view, count: count, active: active) }
    }
}

extension AppDelegate {
    @objc func showFind(_ sender: Any?) { if !MBEngine.performChromeCommand(.find) { store.finder.show() } }
    @objc func findNext(_ sender: Any?) { if !MBEngine.performChromeCommand(.findNext) { store.finder.next(forward: true) } }
    @objc func useSelectionForFind(_ sender: Any?) { store.finder.useSelection() }
    @objc func findPrevious(_ sender: Any?) {
        if !MBEngine.performChromeCommand(.findPrevious) { store.finder.next(forward: false) }
    }
}

extension NSMenu {
    func addingFindItems(target: AppDelegate) -> NSMenu {
        guard let edit = items.first(where: { $0.title == "Edit" })?.submenu else { return self }
        edit.addItem(.separator())
        let entries: [(String, Selector, NSEvent.ModifierFlags)] = [
            ("Find…", #selector(AppDelegate.showFind(_:)), [.command]),
            ("Find Next", #selector(AppDelegate.findNext(_:)), [.command]),
            ("Find Previous", #selector(AppDelegate.findPrevious(_:)), [.command, .shift]),
            ("Use Selection for Find", #selector(AppDelegate.useSelectionForFind(_:)), [.command]),
        ]
        let keys = ["Find…": "f", "Use Selection for Find": "e"]
        for (title, action, modifiers) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keys[title] ?? "g")
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            edit.addItem(item)
        }
        return self
    }
}

@MainActor
final class FindBarView: FlippedView, NSTextFieldDelegate {
    static let size = NSSize(width: 320, height: 36)

    private unowned let finder: PageFinder
    private unowned let container: WebContainerView
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let field = NSTextField()
    private let count = Label.make(size: 12, color: .secondaryLabelColor)
    private let divider = CALayer()
    private lazy var previous = SymbolButton("chevron.up", size: 11) { [weak self] in self?.finder.next(forward: false) }
    private lazy var next = SymbolButton("chevron.down", size: 11) { [weak self] in self?.finder.next(forward: true) }
    private lazy var close = SymbolButton("xmark", size: 10) { [weak self] in self?.finder.close() }

    init(finder: PageFinder, container: WebContainerView) {
        self.finder = finder
        self.container = container
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        isHidden = true
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        layer?.addSublayer(divider)
        icon.image = .symbol("magnifyingglass", size: 12, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(13)
        field.placeholderString = "Find on page"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        count.alignment = .right
        for view in [icon, field, count, previous, next, close] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func update(_ state: FindState) {
        field.setIfChanged(state.query)
        if state.query.isEmpty {
            count.stringValue = ""
        } else if state.matches == 0 {
            count.stringValue = "No results"
        } else {
            count.stringValue = "\(max(state.active, 1)) of \(state.matches)"
        }
        previous.isEnabled = state.matches > 0
        next.isEnabled = state.matches > 0
        needsLayout = true
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func place() {
        guard let card = superview else { return }
        let page = container.pageArea
        let area = page.width > 0 ? page : card.bounds
        let width = min(Self.size.width, area.width)
        frame = NSRect(x: max(area.maxX - width - 12, area.minX), y: card.bounds.height - area.minY - 12 - Self.size.height,
                       width: width, height: Self.size.height)
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
        icon.frame = NSRect(x: 12, y: mid - 7, width: 14, height: 14)
        var x = bounds.width - 6 - 24
        close.frame = NSRect(x: x, y: mid - 12, width: 24, height: 24)
        x -= 4
        divider.frame = NSRect(x: x, y: mid - 7, width: 1, height: 14)
        x -= 4 + 24
        next.frame = NSRect(x: x, y: mid - 12, width: 24, height: 24)
        x -= 24
        previous.frame = NSRect(x: x, y: mid - 12, width: 24, height: 24)
        let width = count.stringValue.isEmpty ? 0 : count.textWidth
        x -= width + 6
        count.frame = NSRect(x: x, y: mid - 8, width: width, height: 16)
        field.frame = NSRect(x: 32, y: mid - 9, width: max(x - 6 - 32, 0), height: 18)
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.backgroundColor = Theme.faint(0.12).cgColor
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        finder.search(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finder.next(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finder.close()
            return true
        default:
            return false
        }
    }
}
