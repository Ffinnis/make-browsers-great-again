import AppKit

enum InspectorTheme {
    static func mono(_ size: CGFloat = 11, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static let font = Theme.font(11.5)
    static let rowHeight: CGFloat = 20

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    static let tag = dynamic(0x9B2393, 0xFC5FA3)
    static let attribute = dynamic(0x815F03, 0xE8A86D)
    static let string = dynamic(0xC41A16, 0xFC6A5D)
    static let number = dynamic(0x1C00CF, 0xD0BF69)
    static let keyword = dynamic(0x9B2393, 0xFC5FA3)
    static let comment = dynamic(0x5D6C79, 0x7F8C98)
    static let property = dynamic(0x326D74, 0x67B7A4)
    static let type = dynamic(0x0B4F79, 0x5DD8FF)
    static let link = dynamic(0x0F68A0, 0x6BB2F5)

    static let error = dynamic(0xD12F1B, 0xFF6B5E)
    static let warning = dynamic(0x9A6700, 0xF5C451)
    static let errorFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.35, green: 0.08, blue: 0.08, alpha: 0.45) : NSColor(srgbRed: 1, green: 0.92, blue: 0.92, alpha: 1)
    }
    static let warningFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.33, green: 0.26, blue: 0.05, alpha: 0.45) : NSColor(srgbRed: 1, green: 0.98, blue: 0.88, alpha: 1)
    }

    static var tint: [RGB] = []
    static let tintChanged = Notification.Name("MBGAInspectorTintChanged")

    static let surface = NSColor(name: nil) { appearance in
        let dark = appearance.isDark
        guard tint.count == 2 else { return dark ? NSColor(white: 0.135, alpha: 1) : .white }
        let middle = tint[0].mixed(with: tint[1], 0.5)
        return (dark ? middle.mixed(with: RGB(0x141416), 0.3) : middle.mixed(with: .white, 0.5)).nsColor
    }
    static let bar = NSColor(name: nil) {
        $0.isDark ? .white.withAlphaComponent(0.035) : .white.withAlphaComponent(0.4)
    }
    static let separator = NSColor(name: nil) {
        $0.isDark ? .white.withAlphaComponent(0.08) : .black.withAlphaComponent(0.07)
    }
    static let selection = Theme.selectedFill
    static let pausedLine = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.2, green: 0.4, blue: 0.2, alpha: 0.6) : NSColor(srgbRed: 0.85, green: 0.95, blue: 0.85, alpha: 1)
    }
    static let breakpoint = NSColor(srgbRed: 0.24, green: 0.5, blue: 0.95, alpha: 1)
}

extension NSMutableAttributedString {
    @discardableResult
    func add(_ text: String, _ color: NSColor = .labelColor, font: NSFont = InspectorTheme.mono()) -> Self {
        append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        return self
    }
}

extension String {
    func clipped(_ limit: Int) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }

    var oneLine: String {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

enum Format {
    static func bytes(_ count: Double) -> String {
        if count < 1000 { return "\(Int(count)) B" }
        if count < 1_000_000 { return String(format: "%.1f kB", count / 1000) }
        if count < 1_000_000_000 { return String(format: "%.1f MB", count / 1_000_000) }
        if count < 1_000_000_000_000 { return String(format: "%.1f GB", count / 1_000_000_000) }
        return String(format: "%.1f TB", count / 1_000_000_000_000)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        return String(format: "%d min %d s", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
class InspectorPanelView: FlippedView {
    private(set) var session: InspectorSession?
    private(set) var isShown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ session: InspectorSession?) {
        guard session !== self.session else { return }
        self.session = session
        sessionChanged()
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { panelDidAppear() } else { panelDidDisappear() }
    }

    func sessionChanged() {}
    func panelDidAppear() {}
    func panelDidDisappear() {}
    func focusFilter() {}
    func selectRow(_ row: Int) {}
}

final class InspectorToolbar: FlippedView {
    static let height: CGFloat = 30
    private var items: [(view: NSView, width: CGFloat?, trailing: Bool)] = []
    private let line = CALayer()
    var bottomLine = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func add(_ view: NSView, width: CGFloat?, trailing: Bool = false) {
        items.append((view, width, trailing))
        addSubview(view)
        needsLayout = true
    }

    func addSeparator() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = InspectorTheme.separator.cgColor
        add(view, width: 1)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 4, inset: CGFloat = 6
        let visible = items.filter { !$0.view.isHidden }
        let fixed = visible.compactMap(\.width).reduce(0, +)
        let flexibleCount = CGFloat(visible.filter { $0.width == nil }.count)
        let spare = max(bounds.width - 2 * inset - fixed - gap * CGFloat(max(visible.count - 1, 0)), 0)
        var x = inset
        var trailingX = bounds.width - inset
        for item in visible where item.trailing {
            let width = item.width ?? 80
            trailingX -= width
            place(item.view, x: trailingX, width: width)
            trailingX -= gap
        }
        for item in visible where !item.trailing {
            let width = item.width ?? (flexibleCount > 0 ? max(spare / flexibleCount, 60) : 0)
            place(item.view, x: x, width: min(width, max(trailingX - x, 0)))
            x += width + gap
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    private func place(_ view: NSView, x: CGFloat, width: CGFloat) {
        let label = (view as? NSTextField).map { !$0.isEditable && !$0.isBezeled } ?? false
        let height: CGFloat = label ? 16 : view.layer?.backgroundColor != nil && width == 1 ? 16 : min(22, bounds.height - 6)
        view.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }

    override func updateLayer() {
        layer?.backgroundColor = InspectorTheme.bar.cgColor
        line.backgroundColor = InspectorTheme.separator.cgColor
        line.isHidden = !bottomLine
        for item in items where item.width == 1 { item.view.layer?.backgroundColor = InspectorTheme.separator.cgColor }
    }
}

final class InspectorButton: HoverView {
    var action: (() -> Void)?
    var isOn = false {
        didSet { if isOn != oldValue { updateColors(); needsDisplay = true } }
    }
    var onColor: NSColor = .controlAccentColor {
        didSet { updateColors() }
    }
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }
    private let imageView = NSImageView()
    private let fill = FillLayer()

    init(_ symbol: String, tip: String, size: CGFloat = 12, action: (() -> Void)? = nil) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        toolTip = tip
        layer?.addSublayer(fill)
        fill.cornerRadius = 5
        imageView.imageScaling = .scaleNone
        imageView.image = .symbol(symbol, size: size)
        addSubview(imageView)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String, size: CGFloat = 12) { imageView.image = .symbol(symbol, size: size) }

    private func updateColors() { imageView.contentTintColor = isOn ? onColor : .secondaryLabelColor }

    override func layout() {
        super.layout()
        fill.frame = bounds
        imageView.frame = bounds
    }

    override func updateLayer() {
        fill.paint(fill: hovering && isEnabled ? Theme.hoverFill : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        imageView.alphaValue = 0.5
    }

    override func mouseUp(with event: NSEvent) {
        imageView.alphaValue = 1
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
}

final class InspectorChips: FlippedView {
    private(set) var titles: [String]
    var selected: Set<Int> = [0] {
        didSet { needsLayout = true; for (i, chip) in chips.enumerated() { chip.on = selected.contains(i) } }
    }
    var multiple = false
    var onChange: ((Set<Int>) -> Void)?
    private var chips: [Chip] = []

    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        for (i, title) in titles.enumerated() {
            let chip = Chip(title) { [weak self] in self?.clicked(i) }
            chip.on = selected.contains(i)
            chips.append(chip)
            addSubview(chip)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredWidth: CGFloat { chips.map(\.width).reduce(0, +) + CGFloat(max(chips.count - 1, 0)) * 2 }

    private func clicked(_ i: Int) {
        if multiple, i != 0, NSEvent.modifierFlags.contains(.command) {
            var set = selected.subtracting([0])
            if set.contains(i) { set.remove(i) } else { set.insert(i) }
            selected = set.isEmpty ? [0] : set
        } else {
            selected = [i]
        }
        onChange?(selected)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for chip in chips {
            chip.frame = NSRect(x: x, y: 0, width: chip.width, height: bounds.height)
            x += chip.width + 2
        }
    }

    private final class Chip: HoverView {
        let label: NSTextField
        let click: () -> Void
        var on = false {
            didSet { needsDisplay = true; label.textColor = on ? .labelColor : .secondaryLabelColor }
        }
        var width: CGFloat { label.textWidth + 10 }

        private let fill = FillLayer()

        init(_ title: String, click: @escaping () -> Void) {
            label = Label.make(title, size: 11, weight: .medium, color: .secondaryLabelColor)
            self.click = click
            super.init(frame: .zero)
            layer?.addSublayer(fill)
            fill.cornerRadius = 6
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            label.frame = NSRect(x: 5, y: (bounds.height - 15) / 2, width: bounds.width - 8, height: 15)
            fill.frame = bounds.insetBy(dx: 0, dy: 1)
        }

        override func updateLayer() {
            fill.paint(fill: on ? Theme.selectedFill : hovering ? Theme.hoverFill : nil,
                       shadow: on ? Theme.selectedShadow : nil, in: effectiveAppearance)
        }

        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { click() }
        }
    }
}

final class InspectorFilterField: NSSearchField {
    var onChange: ((String) -> Void)?
    private let fill = FillLayer()

    override static var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    private final class Cell: NSSearchFieldCell {
        private func centred(_ rect: NSRect) -> NSRect {
            let height = ceil((font?.ascender ?? 10) - (font?.descender ?? -3) + 1)
            return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }

        override func searchTextRect(forBounds rect: NSRect) -> NSRect { centred(super.searchTextRect(forBounds: rect)) }
        override func drawingRect(forBounds rect: NSRect) -> NSRect { centred(super.drawingRect(forBounds: rect)) }
    }

    init(placeholder: String) {
        super.init(frame: .zero)
        placeholderString = placeholder
        controlSize = .small
        font = Theme.font(11)
        sendsSearchStringImmediately = true
        focusRingType = .none
        isBezeled = false
        isBordered = false
        drawsBackground = false
        wantsLayer = true
        layer?.insertSublayer(fill, at: 0)
        fill.cornerRadius = 6
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fill.paint(fill: Theme.controlFill, in: effectiveAppearance)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fill.paint(fill: Theme.controlFill, in: effectiveAppearance)
    }

    @objc private func changed() { onChange?(stringValue) }
}

final class InspectorEmptyView: FlippedView {
    private let label = Label.wrapping("", size: 12, color: .tertiaryLabelColor)

    init(_ text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 32, 280)
        let height = label.sizeThatFits(NSSize(width: width, height: 1000)).height
        label.frame = NSRect(x: (bounds.width - width) / 2, y: max((bounds.height - height) / 2 - 20, 8), width: width, height: height)
    }
}

final class InspectorSplitView: NSSplitView, NSSplitViewDelegate {
    private let key: String
    private let defaultFraction: CGFloat
    private let minimum: CGFloat
    private var restored = false

    init(_ first: NSView, _ second: NSView, vertical: Bool, key: String, fraction: CGFloat = 0.5, minimum: CGFloat = 80) {
        self.key = "inspector.split." + key
        defaultFraction = fraction
        self.minimum = minimum
        super.init(frame: .zero)
        isVertical = vertical
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(first)
        addArrangedSubview(second)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var dividerColor: NSColor { InspectorTheme.separator }

    override func layout() {
        super.layout()
        let length = isVertical ? bounds.width : bounds.height
        guard !restored, length > 0, arrangedSubviews.last?.isHidden == false else { return }
        restored = true
        let saved = UserDefaults.standard.double(forKey: key)
        let fraction = saved > 0 && saved < 1 ? CGFloat(saved) : defaultFraction
        setPosition((length * fraction).rounded(), ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, minimum)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, (isVertical ? bounds.width : bounds.height) - minimum)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard restored, let first = arrangedSubviews.first else { return }
        let length = isVertical ? bounds.width : bounds.height
        guard length > 0, inLiveResize == false, NSEvent.pressedMouseButtons != 0 else { return }
        UserDefaults.standard.set(Double((isVertical ? first.frame.width : first.frame.height) / length), forKey: key)
    }

    func setSecondCollapsed(_ collapsed: Bool) {
        guard arrangedSubviews.count == 2 else { return }
        arrangedSubviews[1].isHidden = collapsed
        adjustSubviews()
        if !collapsed {
            restored = false
            needsLayout = true
        }
    }
}

@MainActor
enum InspectorTable {
    static func make(_ table: NSTableView, columns: [(id: String, title: String, width: CGFloat)],
                     header: Bool = true) -> NSScrollView {
        table.style = .plain
        table.rowHeight = InspectorTheme.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.focusRingType = .none
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 30
            tableColumn.headerCell.font = Theme.font(11, .medium)
            table.addTableColumn(tableColumn)
        }
        if !header { table.headerView = nil }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    static func cell(_ table: NSTableView, _ id: String, _ text: NSAttributedString) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell." + id)
        let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.attributedStringValue = text
        return cell
    }

    static func cell(_ table: NSTableView, _ id: String, _ text: String, color: NSColor = .labelColor,
                     font: NSFont = InspectorTheme.font) -> NSTableCellView {
        cell(table, id, NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
    }
}

class InspectorRowView: NSTableRowView {
    var fill: NSColor?
    var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let fill {
            fill.setFill()
            bounds.fill()
        }
        if hovered, !isSelected {
            Theme.hoverFill.setFill()
            pill.fill()
        }
    }

    private var pill: NSBezierPath {
        let rect = bounds.insetBy(dx: 4, dy: 0.5)
        return NSBezierPath(roundedRect: rect, xRadius: min(6, rect.height / 2), yRadius: min(6, rect.height / 2))
    }

    override func drawSelection(in dirtyRect: NSRect) {
        InspectorTheme.selection.setFill()
        pill.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

class InspectorTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuForRow?(row)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

class InspectorOutlineView: NSOutlineView {
    var menuForRow: ((Int) -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuForRow?(row)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
class ValueNode {
    let name: String
    var dimmed = false
    var children: [ValueNode]?
    var loading = false

    init(name: String) { self.name = name }

    var isExpandable: Bool { false }
    func valueText() -> NSAttributedString { NSAttributedString() }
    func load(_ done: @escaping @MainActor () -> Void) { done() }
    var copyText: String { valueText().string }
}

final class RemoteValueNode: ValueNode {
    let object: JSON
    weak var session: InspectorSession?
    private let accessorOf: String?

    init(name: String, object: JSON, session: InspectorSession?, accessorOf: String? = nil) {
        self.object = object
        self.session = session
        self.accessorOf = accessorOf
        super.init(name: name)
    }

    override var isExpandable: Bool { RemoteValue.isExpandable(object) }

    override func valueText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let summary = RemoteValue.summary(object)
        if object.str("subtype") == "node", let description = object.str("description") {
            return text.add(description, InspectorTheme.tag)
        }
        text.add(summary.clipped(300).oneLine, RemoteValue.color(object))
        return text
    }

    override var copyText: String {
        if object.str("type") == "string" { return object.str("value") ?? "" }
        return RemoteValue.summary(object)
    }

    override func load(_ done: @escaping @MainActor () -> Void) {
        guard let session, let id = object.str("objectId"), children == nil, !loading else { return done() }
        loading = true
        Task {
            async let own = session.send("Runtime.getProperties", ["objectId": id, "ownProperties": true, "generatePreview": true])
            async let inherited = session.send("Runtime.getProperties", ["objectId": id, "ownProperties": false,
                                                                         "accessorPropertiesOnly": true, "generatePreview": true])
            let result = (try? await own) ?? [:]
            let accessors = ((try? await inherited) ?? [:]).list("result").filter { $0.obj("get") != nil && $0.bool("isOwn") == false }
            var nodes: [ValueNode] = []
            let properties = result.list("result")
            let isArray = object.str("subtype") == "array" || object.str("subtype") == "typedarray"
            let sorted = properties.sorted { a, b in
                let (x, y) = (a.str("name") ?? "", b.str("name") ?? "")
                if isArray, let i = Int(x), let j = Int(y) { return i < j }
                if Int(x) != nil, Int(y) == nil { return true }
                if Int(x) == nil, Int(y) != nil { return false }
                return isArray ? false : x.localizedStandardCompare(y) == .orderedAscending
            }
            for property in sorted where property.str("name") != "__proto__" {
                let name = property.str("name") ?? ""
                if let value = property.obj("value") {
                    let node = RemoteValueNode(name: name, object: value, session: session)
                    node.dimmed = !property.bool("enumerable")
                    nodes.append(node)
                } else if property.obj("get") != nil {
                    nodes.append(GetterNode(name: name, owner: id, session: session))
                }
            }
            for accessor in accessors {
                nodes.append(GetterNode(name: accessor.str("name") ?? "", owner: id, session: session))
            }
            for property in result.list("internalProperties") {
                guard let value = property.obj("value") else { continue }
                let node = RemoteValueNode(name: property.str("name") ?? "", object: value, session: session)
                node.dimmed = true
                nodes.append(node)
            }
            for property in result.list("privateProperties") {
                guard let value = property.obj("value") else { continue }
                nodes.append(RemoteValueNode(name: property.str("name") ?? "", object: value, session: session))
            }
            if let proto = properties.first(where: { $0.str("name") == "__proto__" })?.obj("value"),
               proto.str("subtype") != "null" {
                let node = RemoteValueNode(name: "[[Prototype]]", object: proto, session: session)
                node.dimmed = true
                nodes.append(node)
            }
            children = nodes
            loading = false
            done()
        }
    }
}

final class GetterNode: ValueNode {
    private let owner: String
    weak var session: InspectorSession?
    private(set) var value: RemoteValueNode?

    init(name: String, owner: String, session: InspectorSession?) {
        self.owner = owner
        self.session = session
        super.init(name: name)
        dimmed = true
    }

    override var isExpandable: Bool { value?.isExpandable ?? true }

    override func valueText() -> NSAttributedString {
        value?.valueText() ?? NSMutableAttributedString().add("(…)", .secondaryLabelColor)
    }

    override func load(_ done: @escaping @MainActor () -> Void) {
        if let value {
            value.load { [weak self] in
                self?.children = value.children
                done()
            }
            return
        }
        guard let session else { return done() }
        Task {
            let name = (try? JSONSerialization.data(withJSONObject: [self.name], options: [.fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
            let result = try? await session.send("Runtime.callFunctionOn", [
                "objectId": owner, "functionDeclaration": "function(){ return this[\(name)[0]] }",
                "generatePreview": true,
            ])
            if let object = result?.obj("result") {
                value = RemoteValueNode(name: self.name, object: object, session: session)
            }
            children = value?.isExpandable == true ? nil : []
            done()
        }
    }
}

final class JSONValueNode: ValueNode {
    let value: Any

    init(name: String, value: Any) {
        self.value = value
        super.init(name: name)
        if let dict = value as? [String: Any] {
            children = dict.keys.sorted().map { JSONValueNode(name: $0, value: dict[$0]!) }
        } else if let array = value as? [Any] {
            children = array.enumerated().map { JSONValueNode(name: "\($0.offset)", value: $0.element) }
        }
    }

    override var isExpandable: Bool { children?.isEmpty == false }

    override func valueText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        switch value {
        case let string as String: return text.add("\"\(string.clipped(300).oneLine)\"", InspectorTheme.string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return text.add(number.boolValue ? "true" : "false", InspectorTheme.number) }
            return text.add("\(number)", InspectorTheme.number)
        case is NSNull: return text.add("null", .tertiaryLabelColor)
        case let dict as [String: Any]:
            let keys = dict.keys.sorted().prefix(5).map { "\($0): \(Self.short(dict[$0]!))" }.joined(separator: ", ")
            return text.add("{\(keys)\(dict.count > 5 ? ", …" : "")}", .labelColor)
        case let array as [Any]:
            return text.add("(\(array.count)) [\(array.prefix(5).map(Self.short).joined(separator: ", "))\(array.count > 5 ? ", …" : "")]", .labelColor)
        default: return text.add("\(value)")
        }
    }

    private static func short(_ value: Any) -> String {
        switch value {
        case let string as String: "\"\(string.clipped(30).oneLine)\""
        case is [String: Any]: "{…}"
        case let array as [Any]: "Array(\(array.count))"
        case is NSNull: "null"
        default: "\(value)"
        }
    }

    override var copyText: String {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

final class GroupNode: ValueNode {
    private let text: NSAttributedString
    private let loader: ((@escaping @MainActor ([ValueNode]) -> Void) -> Void)?

    init(name: String, value: NSAttributedString = NSAttributedString(), children: [ValueNode]? = nil,
         loader: ((@escaping @MainActor ([ValueNode]) -> Void) -> Void)? = nil) {
        text = value
        self.loader = loader
        super.init(name: name)
        self.children = children
    }

    override var isExpandable: Bool { loader != nil || children?.isEmpty == false }
    override func valueText() -> NSAttributedString { text }

    override func load(_ done: @escaping @MainActor () -> Void) {
        guard children == nil, let loader else { return done() }
        loader { [weak self] nodes in
            self?.children = nodes
            done()
        }
    }
}

final class ValueTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = InspectorOutlineView()
    private(set) var roots: [ValueNode] = []
    var showsNames = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 18
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.menuForRow = { [weak self] row in self?.menu(row) }
        documentView = outline
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ nodes: [ValueNode]) {
        roots = nodes
        outline.reloadData()
    }

    func expandRoots() {
        for node in roots where node.isExpandable { expand(node) }
    }

    func expand(_ node: ValueNode) {
        if node.children != nil {
            outline.expandItem(node)
            return
        }
        node.load { [weak self] in
            self?.outline.reloadItem(node, reloadChildren: true)
            self?.outline.expandItem(node)
        }
    }

    private func menu(_ row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? ValueNode else { return nil }
        let menu = NSMenu()
        menu.add("Copy Value") { Format.copy(node.copyText) }
        if !node.name.isEmpty { menu.add("Copy Property Name") { Format.copy(node.name) } }
        if let remote = node as? RemoteValueNode, let session = remote.session, let id = remote.object.str("objectId") {
            menu.add("Store as Global Variable") {
                Task {
                    _ = try? await session.send("Runtime.callFunctionOn", [
                        "objectId": id, "functionDeclaration":
                            "function(){ let i = 1; while (('temp' + i) in globalThis) i++; globalThis['temp' + i] = this; console.log('temp' + i) }",
                    ])
                }
            }
        }
        return menu
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ValueNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ValueNode else { return roots[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ValueNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? ValueNode else { return false }
        if node.children != nil { return true }
        node.load { [weak self] in
            self?.outline.reloadItem(node, reloadChildren: true)
            self?.outline.expandItem(node)
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ValueNode else { return nil }
        let text = NSMutableAttributedString()
        if showsNames, !node.name.isEmpty {
            text.add(node.name, node.dimmed ? InspectorTheme.property.withAlphaComponent(0.6) : InspectorTheme.property)
            text.add(": ", .secondaryLabelColor)
        }
        text.append(node.valueText())
        return InspectorTable.cell(outlineView, "value", text)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        InspectorRowView()
    }
}

enum CodeLanguage {
    case javascript, css, html, json, plain

    static func guess(mime: String, url: String) -> Self {
        let path = URL(string: url)?.path.lowercased() ?? url.lowercased()
        if mime.contains("json") || path.hasSuffix(".json") || path.hasSuffix(".map") { return .json }
        if mime.contains("javascript") || mime.contains("ecmascript") || [".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx"].contains(where: path.hasSuffix) {
            return .javascript
        }
        if mime.contains("css") || path.hasSuffix(".css") { return .css }
        if mime.contains("html") || mime.contains("xml") || mime.contains("svg") || path.hasSuffix(".html") || path.hasSuffix(".svg") { return .html }
        return .plain
    }
}

enum SyntaxColorer {
    static let codeParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    static let limit = 400_000

    static func color(_ text: String, as language: CodeLanguage, font: NSFont = InspectorTheme.mono()) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                                                                          .paragraphStyle: codeParagraph])
        guard text.utf16.count <= limit, language != .plain else { return result }
        let ns = text as NSString
        func paint(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let range = match?.range(at: group), range.location != NSNotFound else { return }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        switch language {
        case .javascript:
            paint(#"\b(?:break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|function|if|import|in|instanceof|let|new|return|super|switch|this|throw|try|typeof|var|void|while|with|yield|async|await|of|static|get|set|from|as)\b"#, InspectorTheme.keyword)
            paint(#"\b(?:true|false|null|undefined|NaN|Infinity)\b"#, InspectorTheme.keyword)
            paint(#"\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?n?\b|\b0x[\da-f]+\b"#, InspectorTheme.number, options: .caseInsensitive)
            paint(#"\b[A-Z][A-Za-z0-9_$]*\b"#, InspectorTheme.type)
            paint(#"(?<![\w$.])\.?([A-Za-z_$][\w$]*)(?=\s*\()"#, InspectorTheme.property, group: 1)
            paint(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, InspectorTheme.string)
            paint(#"//[^\n]*|/\*[\s\S]*?\*/"#, InspectorTheme.comment)
        case .json:
            paint(#"\b-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\b"#, InspectorTheme.number, options: .caseInsensitive)
            paint(#"\b(?:true|false|null)\b"#, InspectorTheme.keyword)
            paint(#""(?:[^"\\\n]|\\.)*""#, InspectorTheme.string)
            paint(#"("(?:[^"\\\n]|\\.)*")\s*:"#, InspectorTheme.property, group: 1)
        case .css:
            paint(#"([\w-]+)\s*:"#, InspectorTheme.property, group: 1)
            paint(#"#[\da-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, InspectorTheme.number)
            paint(#"@[\w-]+"#, InspectorTheme.keyword)
            paint(#"(^|[}\n])\s*([^{}\n@][^{}\n]*)(?=\{)"#, InspectorTheme.tag, group: 2)
            paint(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, InspectorTheme.string)
            paint(#"/\*[\s\S]*?\*/"#, InspectorTheme.comment)
        case .html:
            paint(#"</?([\w:-]+)"#, InspectorTheme.tag, group: 1)
            paint(#"\s([\w:@.-]+)(?==)"#, InspectorTheme.attribute, group: 1)
            paint(#"=\s*("[^"]*"|'[^']*')"#, InspectorTheme.string, group: 1)
            paint(#"<!--[\s\S]*?-->"#, InspectorTheme.comment)
        case .plain:
            break
        }
        return result
    }
}

final class CodeView: NSScrollView {
    let textView: NSTextView
    private let ruler: LineNumberRuler
    var onGutterClick: ((Int) -> Void)? {
        get { ruler.onClick }
        set { ruler.onClick = newValue }
    }
    var markedLines: Set<Int> {
        get { ruler.marked }
        set { ruler.marked = newValue; ruler.needsDisplay = true }
    }
    var highlightedLine: Int? {
        didSet { updateHighlight() }
    }
    var firstLineNumber: Int {
        get { ruler.first }
        set { ruler.first = newValue; ruler.needsDisplay = true }
    }

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = false
        textView = NSTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = InspectorTheme.mono()
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        documentView = textView
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var wraps = false {
        didSet {
            guard wraps != oldValue, let container = textView.textContainer else { return }
            container.widthTracksTextView = wraps
            textView.isHorizontallyResizable = !wraps
            hasHorizontalScroller = !wraps
            if wraps {
                container.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
                textView.frame.size.width = contentSize.width
            } else {
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            }
        }
    }

    override func layout() {
        super.layout()
        textView.minSize = NSSize(width: wraps ? 0 : contentSize.width, height: contentSize.height)
        if textView.frame.width < contentSize.width || wraps { textView.frame.size.width = contentSize.width }
        if textView.frame.height < contentSize.height { textView.frame.size.height = contentSize.height }
    }

    func show(_ text: String, language: CodeLanguage) {
        textView.textStorage?.setAttributedString(SyntaxColorer.color(text, as: language))
        needsLayout = true
        layoutSubtreeIfNeeded()
        textView.sizeToFit()
        textView.scroll(.zero)
        ruler.invalidateLines()
        updateHighlight()
    }

    var text: String { textView.string }

    func reveal(line: Int, select: Bool = false) {
        guard let range = rangeOf(line: line) else { return }
        textView.layoutManager?.ensureLayout(forCharacterRange: range)
        if select { textView.setSelectedRange(range) }
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerInset.height
        let visible = contentView.bounds.height
        textView.scroll(NSPoint(x: 0, y: max(rect.midY - visible / 2, 0)))
    }

    func rangeOf(line: Int) -> NSRange? {
        let ns = textView.string as NSString
        var start = 0, current = 0
        while current < line {
            let next = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard next.location != NSNotFound else { return nil }
            start = next.location + 1
            current += 1
        }
        let end = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        return NSRange(location: start, length: (end.location == NSNotFound ? ns.length : end.location) - start)
    }

    private func updateHighlight() {
        guard let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        guard let line = highlightedLine, let range = rangeOf(line: line) else { return }
        layout.addTemporaryAttribute(.backgroundColor, value: InspectorTheme.pausedLine,
                                     forCharacterRange: NSRange(location: range.location, length: max(range.length, 1)))
    }
}

private final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var onClick: ((Int) -> Void)?
    var marked: Set<Int> = []
    var first = 1
    private var starts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(tintChanged), name: InspectorTheme.tintChanged, object: nil)
    }

    @objc private func tintChanged() { needsDisplay = true }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func textChanged() { invalidateLines() }

    func invalidateLines() {
        guard let text = textView?.string else { return }
        var starts = [0]
        let utf16 = Array(text.utf16)
        for (i, unit) in utf16.enumerated() where unit == 10 { starts.append(i + 1) }
        self.starts = starts
        let digits = max(String(starts.count + first).count, 2)
        let thickness = CGFloat(digits) * 7 + 18
        if thickness != ruleThickness {
            ruleThickness = thickness
            textView?.textContainerInset = NSSize(width: thickness + 4, height: 4)
        }
        needsDisplay = true
    }

    private func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        InspectorTheme.surface.setFill()
        bounds.fill()
        InspectorTheme.bar.setFill()
        bounds.fill()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: InspectorTheme.mono(10), .foregroundColor: NSColor.tertiaryLabelColor]
        let inset = textView.textContainerInset.height
        let origin = convert(NSPoint.zero, from: textView).y
        var lineIndex = line(at: characters.location)
        while lineIndex < starts.count, starts[lineIndex] <= NSMaxRange(characters) {
            let length = textView.string.utf16.count
            let lineRect: NSRect = if starts[lineIndex] >= length {
                length == 0 ? NSRect(x: 0, y: 0, width: 0, height: 14) : layout.extraLineFragmentRect
            } else {
                layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: starts[lineIndex]), effectiveRange: nil)
            }
            let y = lineRect.minY + inset + origin
            if marked.contains(lineIndex) {
                let mark = NSBezierPath()
                let box = NSRect(x: 2, y: y + 1, width: bounds.width - 4, height: lineRect.height - 2)
                mark.move(to: NSPoint(x: box.minX + 2, y: box.minY))
                mark.line(to: NSPoint(x: box.maxX - 5, y: box.minY))
                mark.line(to: NSPoint(x: box.maxX, y: box.midY))
                mark.line(to: NSPoint(x: box.maxX - 5, y: box.maxY))
                mark.line(to: NSPoint(x: box.minX + 2, y: box.maxY))
                mark.close()
                InspectorTheme.breakpoint.setFill()
                mark.fill()
            }
            let label = "\(lineIndex + first)" as NSString
            var attrs = attributes
            if marked.contains(lineIndex) { attrs[.foregroundColor] = NSColor.white }
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y + (lineRect.height - size.height) / 2), withAttributes: attrs)
            lineIndex += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer, let onClick else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: point.y - textView.textContainerInset.height), in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        onClick(line(at: character))
    }
}

extension NSView {
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }
}
