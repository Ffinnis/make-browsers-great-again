import AppKit

@MainActor
final class DownloadsViewController: NSViewController {
    private let close: () -> Void
    private let heading = Label.make("Downloads", size: 13, weight: .semibold)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let folder = SymbolButton("folder")
    private let empty = Label.make("No downloads yet", size: 12, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [UInt64: DownloadRowView] = [:]

    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 52
    private static let headerHeight: CGFloat = 40
    private static let visibleRows = 6

    init(close: @escaping () -> Void) {
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FlippedView()
        clear.bezelStyle = .accessoryBarAction
        clear.controlSize = .small
        clear.font = Theme.font(11, .medium)
        clear.onAction { DownloadCenter.shared.clear() }
        clear.toolTip = "Remove finished downloads from the list"
        folder.toolTip = "Show Downloads Folder"
        folder.action = { [close] in
            if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(url)
            }
            close()
        }
        empty.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        for view in [heading, clear, folder, empty, scroll] as [NSView] { root.addSubview(view) }
        view = root
        DownloadCenter.shared.observe(self) { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        let items = DownloadCenter.shared.items
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for (index, item) in items.enumerated() {
            let row = rows[item.id] ?? {
                let row = DownloadRowView(close: close)
                rows[item.id] = row
                list.addSubview(row)
                return row
            }()
            row.configure(item, speed: DownloadCenter.shared.speeds[item.id])
            row.frame = NSRect(x: 6, y: CGFloat(index) * Self.rowHeight, width: Self.width - 12, height: Self.rowHeight)
        }
        clear.isEnabled = items.contains { $0.state != .running && $0.state != .paused }
        empty.isHidden = !items.isEmpty
        let shown = min(max(items.count, 1), Self.visibleRows)
        let listHeight = items.isEmpty ? 64 : CGFloat(shown) * Self.rowHeight + 6
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: CGFloat(items.count) * Self.rowHeight + 6)
        preferredContentSize = NSSize(width: Self.width, height: Self.headerHeight + listHeight)
        view.frame.size = preferredContentSize
        layout()
    }

    private func layout() {
        let width = Self.width
        heading.frame = NSRect(x: 16, y: 13, width: 160, height: 18)
        folder.frame = NSRect(x: width - 10 - 28, y: 9, width: 28, height: 24)
        let clearWidth = clear.intrinsicContentSize.width
        clear.frame = NSRect(x: folder.frame.minX - 4 - clearWidth, y: 10, width: clearWidth, height: 22)
        let body = NSRect(x: 0, y: Self.headerHeight, width: width, height: view.bounds.height - Self.headerHeight)
        scroll.frame = body
        empty.frame = NSRect(x: 0, y: body.minY + (body.height - 18) / 2 - 6, width: width, height: 18)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layout()
    }
}

private final class DownloadRowView: HoverView, NSDraggingSource {
    private let close: () -> Void
    private let icon = NSImageView()
    private let name = Label.make("", size: 12.5, weight: .medium)
    private let detail = Label.make("", size: 11, color: .secondaryLabelColor)
    private let fill = FillLayer()
    private let barTrack = FillLayer()
    private let bar = FillLayer()
    private let primary = SymbolButton("xmark", size: 11)
    private let secondary = SymbolButton("pause.fill", size: 10)
    private var item: Download?
    private var dragStart: NSPoint?

    init(close: @escaping () -> Void) {
        self.close = close
        super.init(frame: .zero)
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
        for layer in [barTrack, bar] {
            layer.cornerRadius = 1.5
            self.layer?.addSublayer(layer)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, name, detail, secondary, primary] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var isActive: Bool { item?.state == .running || item?.state == .paused }
    private var canOpen: Bool { item?.state == .done && item?.fileExists == true }

    func configure(_ item: Download, speed: Int64?) {
        let iconChanged = self.item?.state != item.state || self.item?.path != item.path
        self.item = item
        if iconChanged || icon.image == nil { icon.image = item.icon }
        name.setIfChanged(item.name)
        detail.setIfChanged(Self.detail(item, speed: speed))
        alphaValue = item.state == .done && !item.fileExists ? 0.6 : 1
        toolTip = item.url
        configureButtons()
        needsLayout = true
        needsDisplay = true
    }

    private func configureButtons() {
        guard let item else { return }
        switch item.state {
        case .running, .paused:
            primary.setSymbol("xmark", size: 11)
            primary.toolTip = "Cancel"
            primary.action = { DownloadCenter.shared.cancel(item.id) }
            let paused = item.state == .paused
            secondary.setSymbol(paused ? "play.fill" : "pause.fill", size: 10)
            secondary.toolTip = paused ? "Resume" : "Pause"
            secondary.action = { paused ? DownloadCenter.shared.resume(item.id) : DownloadCenter.shared.pause(item.id) }
        case .done where item.fileExists:
            primary.setSymbol("magnifyingglass", size: 11)
            primary.toolTip = "Show in Finder"
            primary.action = { [weak self] in self?.reveal() }
        case .done, .failed, .canceled:
            primary.setSymbol("xmark", size: 11)
            primary.toolTip = "Remove from List"
            primary.action = { DownloadCenter.shared.remove(item.id) }
        }
        updateButtons()
    }

    private func updateButtons() {
        secondary.isHidden = !isActive
        primary.isHidden = !isActive && !hovering
    }

    override func hoverChanged() {
        super.hoverChanged()
        updateButtons()
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func size(_ value: UInt64) -> String { bytes.string(fromByteCount: Int64(clamping: value)) }

    private static func detail(_ item: Download, speed: Int64?) -> String {
        let site = item.host
        switch item.state {
        case .running, .paused:
            var parts = [item.total > 0 ? "\(size(item.received)) of \(size(item.total))" : size(item.received)]
            if item.state == .paused {
                parts.insert("Paused", at: 0)
            } else if let speed, speed > 0 {
                parts.append("\(bytes.string(fromByteCount: speed))/s")
            }
            return parts.joined(separator: " · ")
        case .done:
            guard item.fileExists else { return "Moved or deleted" }
            return [size(item.total), site].filter { !$0.isEmpty }.joined(separator: " · ")
        case .failed:
            return ["Failed", site].filter { !$0.isEmpty }.joined(separator: " · ")
        case .canceled:
            return ["Canceled", site].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = NSRect(x: 8, y: (bounds.height - 32) / 2, width: 32, height: 32)
        primary.frame = NSRect(x: bounds.width - 6 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
        secondary.frame = NSRect(x: primary.frame.minX - 24, y: primary.frame.minY, width: 24, height: 24)
        let textX: CGFloat = 48
        let textRight = (isActive ? secondary.frame.minX : primary.frame.minX) - 4
        name.frame = NSRect(x: textX, y: 8, width: textRight - textX, height: 17)
        let showsBar = isActive
        let detailY: CGFloat = showsBar ? 31 : 27
        detail.frame = NSRect(x: textX, y: detailY, width: textRight - textX, height: 15)
        barTrack.isHidden = !showsBar
        bar.isHidden = !showsBar
        guard showsBar, let item else { return }
        let track = NSRect(x: textX, y: 26, width: textRight - textX, height: 3)
        let fraction = item.total > 0 ? min(1, Double(item.received) / Double(item.total)) : 0
        barTrack.frame = track
        FillLayer.animated(Motion.quick) {
            bar.frame = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        }
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.hoverFill : nil, in: effectiveAppearance)
        barTrack.paint(fill: Theme.faint(0.12), in: effectiveAppearance)
        bar.paint(fill: item?.state == .paused ? .secondaryLabelColor : .controlAccentColor, in: effectiveAppearance)
    }

    private func reveal() {
        guard let url = item?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        close()
    }

    private func open() {
        guard canOpen, let url = item?.fileURL else { return }
        NSWorkspace.shared.open(url)
        close()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, canOpen, let url = item?.fileURL else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragStart = nil
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(icon.frame, contents: icon.image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        if canOpen {
            menu.add("Open") { [weak self] in self?.open() }
            menu.add("Show in Finder") { [weak self] in self?.reveal() }
            menu.addItem(.separator())
        }
        menu.add("Copy Download Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        }
        menu.addItem(.separator())
        if isActive {
            menu.add("Cancel Download") { DownloadCenter.shared.cancel(item.id) }
        } else {
            menu.add("Remove from List") { DownloadCenter.shared.remove(item.id) }
        }
        return menu
    }
}
