import AppKit

@MainActor
class FloatingPanel: NSPanel {
    let card = NSVisualEffectView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        card.material = .menu
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(_ frame: NSRect, over window: NSWindow) {
        setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func dismissPanel() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
final class SuggestionPanel: FloatingPanel {
    var onChoose: ((SavedLogin) -> Void)?
    var onShowAll: (() -> Void)?
    private var logins: [SavedLogin] = []
    private var rows: [SuggestionRow] = []
    private var highlighted: Int?

    private static let rowHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 28
    private static let inset: CGFloat = 5
    private static let shown = 5

    func show(_ logins: [SavedLogin], page: String, under field: NSRect, in window: NSWindow) {
        self.logins = Array(logins.prefix(Self.shown))
        highlighted = nil
        for row in rows { row.removeFromSuperview() }
        rows = self.logins.enumerated().map { i, login in
            let row = SuggestionRow(title: login.username.isEmpty ? "No username" : login.username,
                                    detail: login.site == page ? "Saved for this site" : "Saved for \(login.site)",
                                    symbol: "key.fill")
            row.onHover = { [weak self] in self?.highlight(i) }
            row.onClick = { [weak self] in self?.choose(i) }
            return row
        }
        let footer = SuggestionRow(title: "Passwords…", detail: nil, symbol: nil)
        footer.onHover = { [weak self] in self?.highlight(nil) }
        footer.onClick = { [weak self] in self?.onShowAll?() }
        rows.append(footer)

        let width = min(max(field.width, 260), 380)
        let height = CGFloat(self.logins.count) * Self.rowHeight + Self.footerHeight + Self.inset * 2 + 1
        var y = height - Self.inset
        for (i, row) in rows.enumerated() {
            let h = i < self.logins.count ? Self.rowHeight : Self.footerHeight
            if i == self.logins.count { y -= 1 }
            y -= h
            row.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: h)
            card.addSubview(row)
        }
        var frame = NSRect(x: field.minX, y: field.minY - 4 - height, width: width, height: height)
        if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
            frame.origin.y = field.maxY + 4
        }
        present(frame, over: window)
    }

    func dismiss() {
        dismissPanel()
    }

    func move(_ delta: Int) {
        guard !logins.isEmpty else { return }
        let next = highlighted.map { ($0 + delta + logins.count) % logins.count } ?? (delta > 0 ? 0 : logins.count - 1)
        highlight(next)
    }

    func chooseHighlighted() {
        if let highlighted { choose(highlighted) } else { dismiss() }
    }

    private func highlight(_ index: Int?) {
        highlighted = index
        for (i, row) in rows.enumerated() { row.highlighted = i == index }
    }

    private func choose(_ index: Int) {
        guard logins.indices.contains(index) else { return }
        onChoose?(logins[index])
    }
}

private final class SuggestionRow: FlippedView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var highlighted = false {
        didSet { if highlighted != oldValue { needsDisplay = true; update() } }
    }
    private let icon = NSImageView()
    private let title: NSTextField
    private let detail: NSTextField?

    init(title: String, detail: String?, symbol: String?) {
        self.title = Label.make(title, size: 13, weight: detail == nil ? .regular : .medium)
        self.detail = detail.map { Label.make($0, size: 11, color: .secondaryLabelColor) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        if let symbol {
            icon.image = .symbol(symbol, size: 12, weight: .medium)
            addSubview(icon)
        }
        addSubview(self.title)
        if let detail = self.detail { addSubview(detail) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let left: CGFloat = icon.image == nil ? 10 : 34
        icon.frame = NSRect(x: 10, y: bounds.midY - 8, width: 16, height: 16)
        let width = bounds.width - left - 10
        if let detail {
            title.frame = NSRect(x: left, y: bounds.midY - 17, width: width, height: 17)
            detail.frame = NSRect(x: left, y: bounds.midY + 1, width: width, height: 15)
        } else {
            title.frame = NSRect(x: left, y: bounds.midY - 8, width: width, height: 17)
        }
    }

    private func update() {
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.cgColor : nil
        title.textColor = highlighted ? .white : .labelColor
        detail?.textColor = highlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        icon.contentTintColor = highlighted ? .white : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class SaveOfferPanel: FloatingPanel {
    enum Choice {
        case save, never, notNow
    }

    private(set) var tabID: UInt64?
    private var answer: ((Choice) -> Void)?
    private var timeout: Timer?

    func show(site: String, username: String, update: Bool, tab: UInt64, at view: NSView, in window: NSWindow,
              _ answer: @escaping (Choice) -> Void) {
        tabID = tab
        self.answer = answer
        for subview in card.subviews { subview.removeFromSuperview() }

        let icon = NSImageView(image: .symbol("key.fill", size: 15, weight: .medium) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let headline = Label.make(update ? "Update the password for \(site)?" : "Save the password for \(site)?",
                                  size: 13, weight: .semibold)
        let who = Label.make(username.isEmpty ? "No username" : username, size: 12, color: .secondaryLabelColor)
        let text = NSStackView(views: [headline, who])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 10

        var buttons: [NSView] = []
        if !update {
            buttons.append(button("Never for This Site") { [weak self] in self?.finish(.never) })
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.append(spacer)
        buttons.append(button("Not Now") { [weak self] in self?.finish(.notNow) })
        let save = button(update ? "Update" : "Save") { [weak self] in self?.finish(.save) }
        save.keyEquivalent = "\r"
        buttons.append(save)
        let row = NSStackView(views: buttons)
        row.spacing = 8

        let stack = NSStackView(views: [top, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        let width: CGFloat = 340
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            row.widthAnchor.constraint(equalToConstant: width - 28),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: width - 28 - 25),
        ])
        let height = stack.fittingSize.height

        let page = window.convertToScreen(view.convert(view.bounds, to: nil))
        let frame = NSRect(x: page.maxX - width - 12, y: page.maxY - height - 12, width: width, height: height)
        present(frame, over: window)
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        timeout?.invalidate()
        tabID = nil
        answer = nil
        dismissPanel()
    }

    private func finish(_ choice: Choice) {
        let answer = answer
        dismiss()
        answer?(choice)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton.push(title, action: action)
        button.controlSize = .small
        return button
    }
}

@MainActor
final class PasswordListView: NSStackView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var logins: [SavedLogin] = [] {
        didSet { filter() }
    }
    var onSelect: (() -> Void)?
    private var shown: [SavedLogin] = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = Label.make("No saved passwords", size: 12, color: .tertiaryLabelColor)

    var selected: SavedLogin? {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
    }

    init(width: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        for (id, title, w) in [("site", "Website", width * 0.5), ("user", "Username", width * 0.5)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = w
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            search.widthAnchor.constraint(equalToConstant: width),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        addArrangedSubview(search)
        addArrangedSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let keep = selected?.id
        let words = search.stringValue.lowercased().split(separator: " ")
        shown = logins.filter { login in
            let text = (login.site + " " + login.username).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        table.reloadData()
        if let keep, let row = shown.firstIndex(where: { $0.id == keep }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        empty.isHidden = !shown.isEmpty
        onSelect?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let label = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField
            ?? Label.make(size: 13)
        label.identifier = column.identifier
        let login = shown[row]
        if column.identifier.rawValue == "site" {
            label.stringValue = login.site
            label.textColor = .labelColor
        } else {
            label.stringValue = login.username.isEmpty ? "No username" : login.username
            label.textColor = login.username.isEmpty ? .secondaryLabelColor : .labelColor
        }
        label.toolTip = login.origin
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?() }
}
