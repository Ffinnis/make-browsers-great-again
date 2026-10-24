import AppKit
import UniformTypeIdentifiers

@MainActor
final class DownloadCenter {
    static let shared = DownloadCenter()

    enum Event { case changed, started, finished }

    private struct Observer {
        weak var owner: AnyObject?
        let handle: @MainActor (Event) -> Void
    }

    private var core: BrowserCore?
    private var coreIDs: [UInt32: UInt64] = [:]
    private var engineIDs: [UInt64: UInt32] = [:]
    private(set) var items: [Download] = []
    private(set) var speeds: [UInt64: Int64] = [:]
    private var observers: [Observer] = []
    private var notifyTimer: Timer?
    private var persistTimer: Timer?

    private init() {}

    func start(core: BrowserCore) {
        self.core = core
        items = core.downloads()
        MBEngine.setDownloadHandler { [weak self] download in
            MainActor.assumeIsolated { self?.receive(download) }
        }
    }

    func observe(_ owner: AnyObject, _ handle: @escaping @MainActor (Event) -> Void) {
        observers.append(Observer(owner: owner, handle: handle))
    }

    var active: [Download] { items.filter { $0.state == .running || $0.state == .paused } }

    var progress: Double? {
        let known = active.filter { $0.total > 0 }
        guard !known.isEmpty else { return nil }
        let total = known.reduce(0) { $0 + $1.total }
        let received = known.reduce(0) { $0 + min($1.received, $1.total) }
        return Double(received) / Double(total)
    }

    func cancel(_ id: UInt64) {
        if let engine = engineIDs[id] { MBEngine.cancelDownload(engine) }
    }

    func pause(_ id: UInt64) {
        if let engine = engineIDs[id] { MBEngine.pauseDownload(engine) }
    }

    func resume(_ id: UInt64) {
        if let engine = engineIDs[id] { MBEngine.resumeDownload(engine) }
    }

    func remove(_ id: UInt64) {
        core?.removeDownload(id: id)
        reload(.changed)
    }

    func clear() {
        core?.clearDownloads()
        reload(.changed)
    }

    private func receive(_ download: MBDownload) {
        guard let core else { return }
        let state = Self.state(download.state)
        let started = coreIDs[download.identifier] == nil
        let id = coreIDs[download.identifier] ?? core.startDownload(url: download.url, path: download.path)
        coreIDs[download.identifier] = id
        engineIDs[id] = download.identifier
        speeds[id] = download.speed
        let before = items.first { $0.id == id }?.state
        core.updateDownload(id: id, path: download.path, received: UInt64(max(download.received, 0)),
                            total: UInt64(max(download.total, 0)), state: state)
        if state != .running, state != .paused {
            coreIDs[download.identifier] = nil
            engineIDs[id] = nil
            speeds[id] = nil
        }
        if started {
            reload(.started)
        } else if before != state {
            reload(state == .done ? .finished : .changed)
        } else {
            scheduleNotify()
        }
    }

    private func reload(_ event: Event) {
        guard let core else { return }
        notifyTimer?.invalidate()
        notifyTimer = nil
        items = core.downloads()
        schedulePersist()
        notify(event)
    }

    private func scheduleNotify() {
        guard notifyTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        notifyTimer = timer
    }

    private func flush() {
        guard let core else { return }
        notifyTimer = nil
        items = core.downloads()
        notify(.changed)
    }

    private func schedulePersist() {
        guard persistTimer?.isValid != true else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.core?.persist() }
        }
        RunLoop.main.add(timer, forMode: .common)
        persistTimer = timer
    }

    private func notify(_ event: Event) {
        observers.removeAll { $0.owner == nil }
        for observer in observers where observer.owner != nil {
            observer.handle(event)
        }
    }

    private static func state(_ state: MBDownloadState) -> DownloadState {
        switch state {
        case .running: .running
        case .paused: .paused
        case .done: .done
        case .failed: .failed
        case .canceled: .canceled
        @unknown default: .failed
        }
    }
}

extension Download {
    var fileURL: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }

    var name: String {
        if let fileURL { return fileURL.lastPathComponent }
        let last = URL(string: url)?.lastPathComponent ?? ""
        return last.isEmpty || last == "/" ? "Download" : last
    }

    var host: String {
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var fileExists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    var icon: NSImage {
        if state == .done, fileExists, let fileURL { return NSWorkspace.shared.icon(forFile: fileURL.path) }
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

final class DownloadsButton: HoverView {
    private let imageView = NSImageView()
    private let fill = FillLayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var popover: NSPopover?
    private var showingProgress = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        toolTip = "Downloads"
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = 1.6
            shape.lineCap = .round
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        alphaValue = 0.8
        DownloadCenter.shared.observe(self) { [weak self] event in self?.handle(event) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func handle(_ event: DownloadCenter.Event) {
        update()
        if event != .changed { bounce() }
        if event == .started { announce() }
    }

    private func update() {
        let center = DownloadCenter.shared
        let busy = !center.active.isEmpty
        if busy != showingProgress || imageView.image == nil {
            showingProgress = busy
            imageView.image = .symbol(busy ? "arrow.down" : "arrow.down.circle", size: busy ? 9 : 13,
                                      weight: busy ? .bold : .medium)
            track.isHidden = !busy
            ring.isHidden = !busy
            needsLayout = true
        }
        guard busy else {
            ring.removeAnimation(forKey: "spin")
            return
        }
        if let progress = center.progress {
            ring.removeAnimation(forKey: "spin")
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            ring.strokeEnd = max(0.03, progress)
            CATransaction.commit()
        } else {
            ring.strokeEnd = 0.25
            if ring.animation(forKey: "spin") == nil, !Motion.reduced {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 1
                spin.repeatCount = .infinity
                ring.add(spin, forKey: "spin")
            }
        }
    }

    private func bounce() {
        guard window != nil, !Motion.reduced, let layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1, 1.25, 0.92, 1]
        bounce.keyTimes = [0, 0.35, 0.7, 1]
        bounce.duration = 0.4
        layer.add(bounce, forKey: "bounce")
    }

    private func announce() {
        guard let store = BrowserStore.front, store.layout != .full,
              let download = DownloadCenter.shared.items.first else { return }
        store.showToast(Toast(message: "Downloading “\(download.name)”", symbol: "arrow.down.circle"), duration: 2.5)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        imageView.frame = bounds
        let size: CGFloat = 15
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: -.pi / 2,
                    endAngle: 1.5 * .pi, clockwise: false)
        Motion.instantly {
            for shape in [track, ring] {
                shape.frame = rect
                shape.path = path
            }
        }
    }

    override func updateLayer() {
        fill.paint(fill: hovering || popover != nil ? Theme.hoverFill : nil, in: effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
            ring.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    private static let debugOpen = ProcessInfo.processInfo.environment["MBGA_DEBUG_DOWNLOADS"].flatMap(Double.init)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let delay = Self.debugOpen, window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if let self, popover == nil, window != nil { toggle() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.55
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 0.8
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    private func toggle() {
        if let popover {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.reduced
        popover.contentViewController = DownloadsViewController { [weak popover] in popover?.close() }
        self.popover = popover
        needsDisplay = true
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover = nil
                self?.needsDisplay = true
            }
        }
    }
}
