import AppKit
import CoreImage.CIFilterBuiltins
import Darwin

enum DeveloperSettings {
    static let enabledKey = "developerMode"
    static let everywhereKey = "developerToolbarEverywhere"
    static let collapsesKey = "developerToolbarCollapses"
    static let minimizedKey = "developerToolbarMinimized"
    static let anchorKey = "developerToolbarAnchor"
    static let devToolsInWindowKey = "devToolsInWindow"
    static let devToolsWidthKey = "devToolsWidth"
    static let chromeDevToolsKey = "useChromeDevTools"

    static let debug = ProcessInfo.processInfo.environment["MBGA_DEBUG_DEVELOPER"].flatMap { $0.isEmpty ? nil : $0 }

    static var enabled: Bool { debug != nil || UserDefaults.standard.bool(forKey: enabledKey) }
    static var everywhere: Bool { UserDefaults.standard.bool(forKey: everywhereKey) }
    static var collapses: Bool {
        debug == "expanded" ? false : UserDefaults.standard.object(forKey: collapsesKey) as? Bool ?? true
    }
    static var minimized: Bool { collapses && UserDefaults.standard.bool(forKey: minimizedKey) }
    static var docksDevTools: Bool { !UserDefaults.standard.bool(forKey: devToolsInWindowKey) }
    static var usesChromeDevTools: Bool { UserDefaults.standard.bool(forKey: chromeDevToolsKey) }
    static var anchor: DevToolbarAnchor {
        UserDefaults.standard.string(forKey: anchorKey).flatMap(DevToolbarAnchor.init) ?? .center
    }
}

enum DevToolbarAnchor: String, CaseIterable {
    case leading, center, trailing
}

enum DevSite {
    static func isLocal(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url) else { return false }
        if parts.scheme == "file" { return true }
        guard parts.scheme == "http" || parts.scheme == "https", let host = parts.host?.lowercased() else { return false }
        if host == "localhost" || host == "0.0.0.0" || host == "::1" || host == "[::1]" { return true }
        if [".localhost", ".local", ".test", ".internal"].contains(where: host.hasSuffix) { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    static func isSite(_ url: String) -> Bool {
        ["http", "https", "file"].contains(URLComponents(string: url)?.scheme?.lowercased())
    }

    static func label(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        if parts.scheme == "file" { return (parts.path as NSString).lastPathComponent }
        guard var host = parts.host else { return url }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return parts.port.map { "\(host):\($0)" } ?? host
    }

    static func isLoopback(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host == "::1"
            || host == "[::1]" || host.hasPrefix("127.")
    }

    static func url(_ url: String, onPort port: Int) -> String {
        guard var parts = URLComponents(string: url), parts.host != nil else { return "http://localhost:\(port)/" }
        parts.port = port
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url
    }
}

enum DevPorts {
    static let common = [3000, 3001, 3002, 3333, 4000, 4173, 4200, 4321, 5173, 5174, 5500, 6006,
                         8000, 8001, 8080, 8081, 8787, 8888, 9000]

    static func scan(_ done: @escaping @MainActor ([Int]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var open = [Bool](repeating: false, count: common.count)
            open.withUnsafeMutableBufferPointer { results in
                let results = UnsafeMutableBufferPointer(start: results.baseAddress, count: results.count)
                DispatchQueue.concurrentPerform(iterations: common.count) { i in
                    results[i] = isListening(common[i], v6: false) || isListening(common[i], v6: true)
                }
            }
            let ports = common.indices.filter { open[$0] }.map { common[$0] }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ports) } }
        }
    }

    private static func isListening(_ port: Int, v6: Bool) -> Bool {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var result: Int32
        if v6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 150) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}

enum DevShare {
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("en") { return ip }
            if found == nil, !name.hasPrefix("utun") { found = ip }
        }
        return found
    }

    static func phoneURL(_ url: String) -> String {
        guard DevSite.isLoopback(url), var parts = URLComponents(string: url), let lan = lanAddress() else { return url }
        parts.host = lan
        return parts.string ?? url
    }

    static func qrCode(_ text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scale = (size * 2 / code.extent.width).rounded(.down)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
        image.addRepresentation(rep)
        return image
    }
}

struct DevicePreset: Equatable {
    let name: String
    let symbol: String
    let width: CGFloat
    let height: CGFloat
    let userAgent: String?

    private static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    private static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    private static let android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36"

    static let all = [
        Self(name: "iPhone 16 Pro", symbol: "iphone", width: 402, height: 874, userAgent: iPhone),
        Self(name: "iPhone SE", symbol: "iphone.gen1", width: 375, height: 667, userAgent: iPhone),
        Self(name: "Pixel 9", symbol: "smartphone", width: 412, height: 923, userAgent: android),
        Self(name: "iPad mini", symbol: "ipad", width: 744, height: 1133, userAgent: iPad),
        Self(name: "iPad Pro 11″", symbol: "ipad", width: 834, height: 1210, userAgent: iPad),
        Self(name: "Laptop", symbol: "laptopcomputer", width: 1280, height: 800, userAgent: nil),
    ]
}

enum NetworkPreset: CaseIterable {
    case unthrottled, fast4G, slow4G, threeG, offline

    var title: String {
        switch self {
        case .unthrottled: "No Throttling"
        case .fast4G: "Fast 4G"
        case .slow4G: "Slow 4G"
        case .threeG: "3G"
        case .offline: "Offline"
        }
    }

    var conditions: (latency: Double, throughput: Double) {
        switch self {
        case .unthrottled: (0, 0)
        case .fast4G: (60, 9_000_000 / 8)
        case .slow4G: (150, 1_600_000 / 8)
        case .threeG: (300, 780_000 / 8)
        case .offline: (0, -1)
        }
    }
}

enum ColorSchemePreview: String {
    case system, dark, light

    var next: Self {
        switch self {
        case .system: .dark
        case .dark: .light
        case .light: .system
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        }
    }

    var title: String {
        switch self {
        case .system: "Match System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

struct DevTabState: Equatable {
    var colorScheme = ColorSchemePreview.system
    var reducedMotion = false
    var cacheDisabled = false
    var scriptsDisabled = false
    var network = NetworkPreset.unthrottled
    var device: DevicePreset?
    var landscape = false
    var picking = false

    var viewport: NSSize? {
        device.map { landscape ? NSSize(width: $0.height, height: $0.width) : NSSize(width: $0.width, height: $0.height) }
    }
}

struct DevPageReport: Equatable {
    var errors = 0
    var warnings = 0
    var status: Int?
    var duration: TimeInterval?

    var statusText: String? {
        guard let status else { return nil }
        guard status < 0 else { return status == 0 ? nil : "\(status)" }
        switch status {
        case -102: return "Refused"
        case -105, -137: return "No host"
        case -106: return "Offline"
        case -7, -118: return "Timed out"
        case -101: return "Reset"
        case -324: return "Empty reply"
        case -299 ... -200: return "Certificate"
        default: return "Failed"
        }
    }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        return duration < 1 ? "\(Int((duration * 1000).rounded())) ms" : String(format: "%.1f s", duration)
    }
}

extension MBWebView {
    func apply(_ state: DevTabState, from old: DevTabState = DevTabState()) {
        if state.colorScheme != old.colorScheme {
            emulateMediaFeature("prefers-color-scheme", value: state.colorScheme == .system ? "" : state.colorScheme.rawValue)
        }
        if state.reducedMotion != old.reducedMotion {
            emulateMediaFeature("prefers-reduced-motion", value: state.reducedMotion ? "reduce" : "")
        }
        if state.cacheDisabled != old.cacheDisabled { setCacheDisabled(state.cacheDisabled) }
        if state.scriptsDisabled != old.scriptsDisabled { setScriptsDisabled(state.scriptsDisabled) }
        if state.network != old.network {
            let conditions = state.network.conditions
            emulateNetwork(withLatency: conditions.latency, throughput: conditions.throughput)
        }
        if state.device != old.device { emulateMobile(withUserAgent: state.device?.userAgent) }
        if state.picking != old.picking { setPicking(state.picking) }
    }
}

@MainActor
final class DevToolbarView: NSView {
    private let store: BrowserStore
    private let pill: DevPillView
    private var presence = Spring(0, response: 0.26 * Motion.slow)
    private var expansion = Spring(0, response: 0.24 * Motion.slow)
    private var position = Spring(0, response: Motion.springResponse)
    private lazy var ticker = FrameTicker("dev toolbar") { [weak self] time in self?.step(at: time) }
    private var lastTick: CFTimeInterval?
    private var collapseTimer: Timer?
    private var anchor = DeveloperSettings.anchor
    private var dragStart: (pointer: CGFloat, center: CGFloat)?
    private var sliding = false

    static let height: CGFloat = 56

    init(store: BrowserStore) {
        self.store = store
        pill = DevPillView(store: store)
        super.init(frame: .zero)
        addSubview(pill)
        isHidden = true
        pill.onHover = { [weak self] hovering in self?.hoverChanged(hovering) }
        pill.onDrag = { [weak self] phase, x in self?.drag(phase, x) }
        pill.onMenuClosed = { [weak self] in self?.hoverChanged(self?.pill.isUnderPointer == true) }
        store.observe(self) { [weak self] change in
            switch change {
            case .snapshot, .nav, .developer, .chrome:
                self?.update()
            default:
                break
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, presence.target == 1 else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc private func defaultsChanged() {
        let anchor = DeveloperSettings.anchor
        if anchor != self.anchor, dragStart == nil {
            self.anchor = anchor
            sliding = true
            run()
        }
        update()
    }

    private var expanded: Bool {
        !DeveloperSettings.collapses || pill.isUnderPointer || pill.menuOpen || store.visibleDevState.picking
    }

    private func update() {
        let shown = store.developerToolbarShown
        pill.update()
        if shown, isHidden {
            isHidden = false
            presence.settle()
            presence.value = 0
        }
        presence.target = shown ? 1 : 0
        if !shown { collapseTimer?.invalidate() }
        expansion.target = shown && (expanded || collapseTimer?.isValid == true) ? 1 : 0
        if window == nil || Motion.reduced {
            presence.settle()
            expansion.settle()
        }
        needsLayout = true
        run()
    }

    private func hoverChanged(_ hovering: Bool) {
        collapseTimer?.invalidate()
        if hovering || expanded {
            expansion.target = 1
            pill.scanPorts()
        } else {
            let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.expanded { self.expansion.target = 0 }
                    self.run()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            collapseTimer = timer
        }
        run()
    }

    private func drag(_ phase: DevPillView.DragPhase, _ x: CGFloat) {
        switch phase {
        case .began:
            dragStart = (x, position.value)
        case .moved:
            guard let start = dragStart else { return }
            let half = pill.frame.width / 2
            let center = min(max(start.center + x - start.pointer, half + 8), bounds.width - half - 8)
            position.velocity = (center - position.value) * 60
            position.value = center
            position.target = center
            needsLayout = true
        case .ended:
            dragStart = nil
            let third = bounds.width / 3
            anchor = position.value < third ? .leading : position.value > 2 * third ? .trailing : .center
            if DeveloperSettings.debug == nil {
                UserDefaults.standard.set(anchor.rawValue, forKey: DeveloperSettings.anchorKey)
            }
            sliding = true
            run()
        }
    }

    private func anchorCenter(width: CGFloat) -> CGFloat {
        switch anchor {
        case .leading: 12 + width / 2
        case .center: bounds.width / 2
        case .trailing: bounds.width - 12 - width / 2
        }
    }

    private func run() {
        guard window != nil, !Motion.reduced else {
            presence.settle()
            expansion.settle()
            sliding = false
            finishIfGone()
            needsLayout = true
            return
        }
        lastTick = nil
        ticker.start(on: self)
    }

    private func step(at time: CFTimeInterval) {
        let dt = min(time - (lastTick ?? time - 1.0 / 120), 1.0 / 30)
        lastTick = time
        presence.step(dt)
        expansion.step(dt)
        if sliding {
            position.target = anchorCenter(width: pill.width(expanded: expansion.value))
            position.step(dt)
            if position.isSettled { sliding = false }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if presence.isSettled, expansion.isSettled, !sliding, dragStart == nil {
            ticker.stop()
            finishIfGone()
        }
    }

    private func finishIfGone() {
        if presence.target == 0, presence.isSettled { isHidden = true }
    }

    override func layout() {
        super.layout()
        let e = expansion.value
        let width = pill.width(expanded: e)
        let height = pill.height(expanded: e)
        let top = pill.minimized ? 6 + 2 * e : 8
        if !sliding, dragStart == nil {
            position.target = anchorCenter(width: width)
            position.settle()
        }
        let p = presence.value
        let half = width / 2
        let center = min(max(position.value, half + 8), max(bounds.width - half - 8, half + 8))
        pill.expansion = e
        pill.frame = NSRect(x: (center - half).rounded(), y: top - 6 * (1 - p), width: width.rounded(), height: height)
        pill.alphaValue = min(max(p, 0), 1)
    }
}

@MainActor
final class DevPillView: HoverView {
    enum DragPhase { case began, moved, ended }

    var onHover: ((Bool) -> Void)?
    var onDrag: ((DragPhase, CGFloat) -> Void)?
    var onMenuClosed: (() -> Void)?
    private(set) var menuOpen = false
    private(set) var minimized = DeveloperSettings.minimized
    private var troubled = false
    var expansion: CGFloat = 0 {
        didSet { if expansion != oldValue { needsLayout = true } }
    }

    private let store: BrowserStore
    private let glass: NSView
    private let halo = NSVisualEffectView()
    private let wideShadow = CALayer()
    private let contactShadow = CALayer()
    private static let haloSpread: CGFloat = 18
    private let content = FlippedView()
    private let host = Label.make(size: 12, weight: .medium)
    private let problem = Label.make(size: 12, weight: .semibold)
    private let errors = DevCount(symbol: "xmark.octagon.fill", color: .systemRed)
    private let warnings = DevCount(symbol: "exclamationmark.triangle.fill", color: .systemYellow)
    private let time = Label.make(size: 11, color: .tertiaryLabelColor)
    private let reload = DevButton("arrow.clockwise", tip: "Reload Without Cache  ⇧⌘R")
    private let pick = DevButton("cursorarrow.rays", tip: "Pick an Element  ⌥⌘C")
    private let devtools = DevButton("terminal", tip: "Developer Tools  ⌥⌘I")
    private let scheme = DevButton("circle.lefthalf.filled", tip: "Colour Scheme")
    private let device = DevButton("iphone", tip: "Device Preview")
    private let more = DevButton("ellipsis", tip: "More")
    private var ports: [Int] = []
    private var lastScan: Date?
    private var mouseDownX: CGFloat?
    private var dragging = false

    private var tools: [DevButton] {
        [reload, pick, devtools] + (scheme.isHidden ? [] : [scheme]) + [device, more]
    }

    init(store: BrowserStore) {
        self.store = store
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = content
            self.glass = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.masksToBounds = true
            material.layer?.cornerCurve = .continuous
            material.addSubview(content)
            glass = material
        }
        super.init(frame: .zero)
        layer?.masksToBounds = false
        halo.material = .popover
        halo.blendingMode = .withinWindow
        halo.state = .active
        halo.maskImage = Self.haloMask
        addSubview(halo)
        for shadow in [wideShadow, contactShadow] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 1
            layer?.addSublayer(shadow)
        }
        addSubview(glass)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        problem.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        problem.textColor = .systemRed
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for view in [host, problem, errors, warnings, time, reload, pick, devtools, scheme, device, more] as [NSView] {
            content.addSubview(view)
        }
        errors.action = { store.openDevTools() }
        warnings.action = { store.openDevTools() }
        reload.action = { store.hardReload() }
        pick.action = { store.togglePicking() }
        devtools.action = { store.showDevTools() }
        scheme.action = { store.updateDev { $0.colorScheme = $0.colorScheme.next } }
        device.action = { [weak self] in self?.showMenu(self?.deviceMenu(), under: self?.device) }
        more.action = { [weak self] in self?.showMenu(self?.moreMenu(), under: self?.more) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        minimized = DeveloperSettings.minimized
        let url = store.visibleTab?.url ?? ""
        let state = store.visibleDevState
        let report = store.visibleDevReport
        let loading = store.nav.isLoading
        if state.picking {
            host.attributedStringValue = attributed("Click an element", port: nil)
        } else {
            let label = DevSite.label(url)
            let split = label.lastIndex(of: ":").map { (String(label[..<$0]), String(label[$0...])) }
            host.attributedStringValue = attributed(split?.0 ?? label, port: split?.1)
        }
        Motion.animate(Motion.quick) { host.animator().alphaValue = loading ? 0.45 : 1 }
        let failed = report.status.map { $0 < 0 || $0 >= 400 } ?? false
        problem.setIfChanged(failed && !loading ? report.statusText ?? "" : "")
        problem.toolTip = report.status.map { $0 < 0 ? "The page didn't load (error \($0))" : "Status \($0)" }
        time.setIfChanged(!failed && !loading ? report.durationText ?? "" : "")
        time.toolTip = report.durationText.map { "Loaded in \($0)" }
        errors.count = report.errors
        troubled = (failed && !loading) || report.errors > 0
        warnings.count = report.warnings
        errors.toolTip = "\(report.errors) console error\(report.errors == 1 ? "" : "s"): open Developer Tools"
        warnings.toolTip = "\(report.warnings) console warning\(report.warnings == 1 ? "" : "s"): open Developer Tools"
        pick.isOn = state.picking
        devtools.isOn = store.visibleDevToolsOpen
        scheme.isHidden = state.colorScheme == .system
        scheme.isOn = true
        scheme.setSymbol(state.colorScheme.symbol)
        scheme.toolTip = "Previewing \(state.colorScheme.title.lowercased()) mode: click to change"
        device.isOn = state.device != nil
        device.setSymbol(state.device?.symbol ?? "iphone")
        device.toolTip = state.device.map { d in
            let size = state.viewport ?? .zero
            return "\(d.name), \(Int(size.width)) × \(Int(size.height))"
        } ?? "Device Preview"
        more.isOn = state.cacheDisabled || state.scriptsDisabled || state.network != .unthrottled || state.reducedMotion
        needsLayout = true
    }

    private func attributed(_ name: String, port: String?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: Theme.font(12, .medium), .foregroundColor: NSColor.labelColor,
        ])
        if let port {
            text.append(NSAttributedString(string: port, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private static let collapsedHeight: CGFloat = 26
    private static let expandedHeight: CGFloat = 32
    private static let handleSize = NSSize(width: 40, height: 10)

    private var statusWidth: CGFloat {
        var width = 12 + host.textWidth
        if !problem.stringValue.isEmpty { width += 6 + problem.textWidth }
        for count in [errors, warnings] where count.count > 0 { width += 4 + count.preferredWidth }
        return width
    }

    private var toolsWidth: CGFloat {
        let timeWidth = time.stringValue.isEmpty ? 0 : 6 + time.textWidth
        return timeWidth + 10 + CGFloat(tools.count) * 28 + CGFloat(tools.count - 1) * 2 + 4
    }

    func width(expanded e: CGFloat) -> CGFloat {
        let collapsed = minimized ? Self.handleSize.width : statusWidth + 12
        return collapsed + (statusWidth + toolsWidth - collapsed) * e
    }

    func height(expanded e: CGFloat) -> CGFloat {
        let collapsed = minimized ? Self.handleSize.height : Self.collapsedHeight
        return collapsed + (Self.expandedHeight - collapsed) * e
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = bounds.height / 2
        let spread = Self.haloSpread
        halo.frame = bounds.insetBy(dx: -spread, dy: -spread).offsetBy(dx: 0, dy: 3)
        let capsule = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shadow in [wideShadow, contactShadow] {
            shadow.frame = bounds
            shadow.shadowPath = capsule
        }
        glass.frame = bounds
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glass.layer?.cornerRadius = radius
            glass.layer?.borderWidth = 0.5
            glass.layer?.borderColor = Theme.faint(0.12).cgColor
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        content.frame = glass.bounds
        content.layer?.cornerRadius = radius
        content.layer?.backgroundColor = minimized && troubled
            ? NSColor.systemRed.withAlphaComponent(0.8 * (1 - expansion)).cgColor : nil
        CATransaction.commit()
        let mid = bounds.height / 2
        let alpha = min(max((expansion - 0.3) / 0.7, 0), 1)
        for view in [host, problem, errors, warnings] as [NSView] { view.alphaValue = minimized ? alpha : 1 }
        var x: CGFloat = 12
        let hostWidth = host.textWidth
        host.frame = NSRect(x: x, y: mid - 8, width: hostWidth, height: 16)
        x += hostWidth
        problem.isHidden = problem.stringValue.isEmpty
        if !problem.isHidden {
            x += 6
            problem.frame = NSRect(x: x, y: mid - 8, width: problem.textWidth, height: 16)
            x += problem.textWidth
        }
        for count in [errors, warnings] {
            count.isHidden = count.count == 0
            guard count.count > 0 else { continue }
            x += 4
            count.frame = NSRect(x: x, y: mid - 10, width: count.preferredWidth, height: 20)
            x += count.preferredWidth
        }
        time.isHidden = time.stringValue.isEmpty
        if !time.isHidden {
            x += 6
            time.frame = NSRect(x: x, y: mid - 7.5, width: time.textWidth, height: 15)
            time.alphaValue = alpha
            x += time.textWidth
        }
        x += 10
        for tool in tools {
            tool.frame = NSRect(x: x, y: mid - 12, width: 28, height: 24)
            tool.alphaValue = alpha
            x += 30
        }
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        wideShadow.shadowRadius = 20
        wideShadow.shadowOffset = CGSize(width: 0, height: 10)
        wideShadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.28).cgColor
        contactShadow.shadowRadius = 3
        contactShadow.shadowOffset = CGSize(width: 0, height: 1)
        contactShadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.14).cgColor
    }

    private static let haloMask: NSImage = {
        let spread = haloSpread, height: CGFloat = 32 + 2 * haloSpread
        let size = NSSize(width: height * 2, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let core = rect.insetBy(dx: spread, dy: spread)
            let path = CGPath(roundedRect: core, cornerWidth: core.height / 2, cornerHeight: core.height / 2, transform: nil)
            context.setShadow(offset: CGSize(width: 0, height: -2000), blur: spread * 0.9, color: NSColor.black.cgColor)
            context.translateBy(x: 0, y: 2000)
            context.addPath(path)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: height / 2, left: height / 2, bottom: height / 2 - 1, right: height / 2)
        image.resizingMode = .stretch
        return image
    }()

    override func hoverChanged() {
        onHover?(hovering)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownX = event.locationInWindow.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownX else { return }
        if !dragging, abs(event.locationInWindow.x - start) > 3 {
            dragging = true
            onDrag?(.began, start)
            NSCursor.closedHand.push()
        }
        if dragging { onDrag?(.moved, event.locationInWindow.x) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownX = nil }
        if dragging {
            dragging = false
            NSCursor.pop()
            onDrag?(.ended, event.locationInWindow.x)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if point.x < statusWidth { showMenu(addressMenu(), under: nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        hideItems(in: menu)
        showMenu(menu, under: nil)
    }

    func scanPorts() {
        if let lastScan, Date().timeIntervalSince(lastScan) < 4 { return }
        lastScan = Date()
        DevPorts.scan { [weak self] ports in self?.ports = ports }
    }

    private func showMenu(_ menu: NSMenu?, under view: NSView?) {
        guard let menu else { return }
        menuOpen = true
        let anchor = view ?? self
        menu.popUp(positioning: nil, at: NSPoint(x: view == nil ? 8 : 0, y: anchor.bounds.height + 6), in: anchor)
        menuOpen = false
        onMenuClosed?()
    }

    private func addressMenu() -> NSMenu {
        let menu = NSMenu()
        let url = store.visibleTab?.url ?? ""
        let shown = NSMenuItem(title: url, action: nil, keyEquivalent: "")
        shown.isEnabled = false
        menu.addItem(shown)
        menu.add("Copy URL") { [store] in store.copyVisibleURL() }
        menu.addItem(.separator())
        let current = URLComponents(string: url)?.port
        let header = NSMenuItem(title: ports.isEmpty ? "No Dev Servers Running" : "Dev Servers on This Mac", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for port in ports {
            menu.add("localhost:\(port)", state: port == current) { [store] in
                store.loadInVisibleTab(DevSite.isLoopback(url) ? DevSite.url(url, onPort: port) : "http://localhost:\(port)/")
            }
        }
        return menu
    }

    private func deviceMenu() -> NSMenu {
        let menu = NSMenu()
        let state = store.visibleDevState
        menu.add("Off", state: state.device == nil) { [store] in store.setDevice(nil) }
        menu.addItem(.separator())
        for preset in DevicePreset.all {
            let item = menu.add(preset.name, state: state.device == preset) { [store] in store.setDevice(preset) }
            item.image = .symbol(preset.symbol, size: 13)
            item.toolTip = "\(Int(preset.width)) × \(Int(preset.height))"
        }
        menu.addItem(.separator())
        menu.add("Landscape", state: state.landscape, enabled: state.device != nil) { [store] in
            store.updateDev { $0.landscape.toggle() }
        }
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        let state = store.visibleDevState
        menu.addSubmenu(titled: "Colour Scheme") { sub in
            for preview in [ColorSchemePreview.system, .dark, .light] {
                sub.add(preview.title, state: state.colorScheme == preview) { [store] in
                    store.updateDev { $0.colorScheme = preview }
                }
            }
        }
        menu.add("Screenshot the Whole Page") { [store] in store.screenshotPage() }
        menu.add("Open on a Phone…") { [weak self] in self?.showPhone() }
        menu.add("Copy URL") { [store] in store.copyVisibleURL() }
        menu.addItem(.separator())
        menu.add("Disable Cache", state: state.cacheDisabled) { [store] in store.updateDev { $0.cacheDisabled.toggle() } }
        menu.addSubmenu(titled: "Network") { sub in
            for preset in NetworkPreset.allCases {
                sub.add(preset.title, state: state.network == preset) { [store] in store.updateDev { $0.network = preset } }
            }
        }
        menu.add("Disable JavaScript", state: state.scriptsDisabled) { [store] in store.toggleScripts() }
        menu.add("Prefer Reduced Motion", state: state.reducedMotion) { [store] in store.updateDev { $0.reducedMotion.toggle() } }
        menu.addItem(.separator())
        menu.add("Clear Site Data and Reload") { [store] in store.clearSiteData() }
        menu.add("View Page Source") { [store] in store.viewSource() }
        menu.addSubmenu(titled: "Open Page In") { sub in
            for browser in DevBrowsers.installed {
                let item = sub.add(browser.name) { [store] in store.openVisible(in: browser.url) }
                item.image = browser.icon
            }
        }
        menu.addItem(.separator())
        hideItems(in: menu)
        return menu
    }

    private func hideItems(in menu: NSMenu) {
        menu.add("Shrink to a Small Handle", state: DeveloperSettings.minimized) {
            let on = !DeveloperSettings.minimized
            UserDefaults.standard.set(on, forKey: DeveloperSettings.minimizedKey)
            if on { UserDefaults.standard.set(true, forKey: DeveloperSettings.collapsesKey) }
        }
        let hide = menu.add("Hide Toolbar on This Tab") { [store] in store.toggleDeveloperToolbar() }
        hide.keyEquivalent = "d"
        hide.keyEquivalentModifierMask = [.command, .shift]
        menu.add("Developer Settings…") { [store] in store.openSettings?(.developer) }
    }

    private func showPhone() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = DevPhoneViewController(url: DevShare.phoneURL(store.visibleTab?.url ?? ""))
            menuOpen = true
            popover.show(relativeTo: more.bounds, of: more, preferredEdge: .maxY)
            NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuOpen = false
                    self?.onMenuClosed?()
                }
            }
        }
    }
}

final class DevButton: HoverView {
    var action: (() -> Void)?
    var isOn = false {
        didSet { if isOn != oldValue { FillLayer.animated(Motion.quick) { updateLayer() } } }
    }
    private let image = NSImageView()
    private let fill = FillLayer()

    init(_ symbol: String, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        toolTip = tip
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        image.imageScaling = .scaleNone
        addSubview(image)
        setSymbol(symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ name: String) {
        image.image = .symbol(name, size: 13)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        image.frame = bounds
    }

    override func updateLayer() {
        let fillColor: NSColor? = isOn ? NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.2 : 0.14)
            : hovering ? Theme.faint(0.07) : nil
        fill.paint(fill: fillColor, in: effectiveAppearance)
        image.contentTintColor = isOn ? .controlAccentColor : Theme.faint(0.8)
    }

    override func mouseDown(with event: NSEvent) { image.alphaValue = 0.55 }

    override func mouseUp(with event: NSEvent) {
        image.alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

final class DevCount: HoverView {
    var action: (() -> Void)?
    var count = 0 {
        didSet { if count != oldValue { label.stringValue = count > 99 ? "99+" : "\(count)" } }
    }
    private let icon = NSImageView()
    private let label = Label.make(size: 12, weight: .medium, color: .secondaryLabelColor)
    private let fill = FillLayer()

    init(symbol: String, color: NSColor) {
        super.init(frame: .zero)
        fill.cornerRadius = 6
        layer?.addSublayer(fill)
        icon.image = .symbol(symbol, size: 10.5, weight: .semibold)
        icon.contentTintColor = color
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredWidth: CGFloat { 4 + 12 + 3 + label.textWidth }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = NSRect(x: 4, y: bounds.midY - 6, width: 12, height: 12)
        label.frame = NSRect(x: 19, y: bounds.midY - 8, width: label.textWidth, height: 16)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.faint(0.07) : nil, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

enum DevBrowsers {
    struct Browser {
        let name: String
        let url: URL
        var icon: NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }

    static var installed: [Browser] {
        let ids = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                   "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
                   "com.kagi.kagimacOS", "app.zen-browser.zen"]
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return Browser(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
    }
}

final class DevPhoneViewController: NSViewController {
    private let url: String

    init(url: String) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 240, height: 296))
        let code = NSImageView(frame: NSRect(x: 30, y: 18, width: 180, height: 180))
        code.image = DevShare.qrCode(url, size: 180)
        code.imageScaling = .scaleProportionallyUpOrDown
        code.wantsLayer = true
        code.layer?.backgroundColor = NSColor.white.cgColor
        code.layer?.cornerRadius = 10
        code.layer?.cornerCurve = .continuous
        let title = Label.make("Scan with your phone's camera", size: 12, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 12, y: 210, width: 216, height: 16)
        let address = Label.make(url, size: 11, color: .secondaryLabelColor)
        address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        address.alignment = .center
        address.lineBreakMode = .byTruncatingMiddle
        address.frame = NSRect(x: 12, y: 230, width: 216, height: 15)
        let note = Label.wrapping("Same Wi-Fi only. Your dev server must listen on all addresses (e.g. --host).", size: 11)
        note.alignment = .center
        note.frame = NSRect(x: 16, y: 252, width: 208, height: 32)
        for subview in [code, title, address, note] { view.addSubview(subview) }
        self.view = view
    }
}
