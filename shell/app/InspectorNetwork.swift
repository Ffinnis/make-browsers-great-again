import AppKit

@MainActor
final class NetRequest {
    fileprivate(set) var key: String
    let requestID: String
    let loaderID: String
    let url: String
    let method: String
    var type: String
    var status: Int?
    var statusText = ""
    var mime = ""
    var requestHeaders: [(name: String, value: String)] = []
    var responseHeaders: [(name: String, value: String)] = []
    var rawRequestHeaders: [(name: String, value: String)]?
    var rawResponseHeaders: [(name: String, value: String)]?
    var responseHeadersText: String?
    var postData: String?
    var hasPostData = false
    var referrerPolicy: String?
    var initiator: JSON?
    var timing: JSON?
    var transferred: Double = 0
    var resourceSize: Double = 0
    let start: Double
    let wallTime: Double
    var responseTime: Double?
    var end: Double?
    var failure: String?
    var canceled = false
    var blockedReason: String?
    var cache: String?
    var remoteAddress: String?
    var protocolName: String?
    var frames: [NetFrame] = []
    var isRedirect = false
    var version = 0

    init(requestID: String, loaderID: String, url: String, method: String, type: String, start: Double, wallTime: Double) {
        key = requestID
        self.requestID = requestID
        self.loaderID = loaderID
        self.url = url
        self.method = method
        self.type = type
        self.start = start
        self.wallTime = wallTime
    }

    var isFinished: Bool { end != nil }
    var isFailed: Bool { failure != nil || (status ?? 0) >= 400 }

    lazy var displayName: String = {
        if url.hasPrefix("data:") { return String(url.prefix(40)) }
        guard let parts = URLComponents(string: url) else { return url }
        var name = (parts.path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { name = parts.host ?? url }
        if let query = parts.percentEncodedQuery, !query.isEmpty { name += "?" + query }
        return name
    }()

    lazy var host: String = URLComponents(string: url)?.host ?? ""

    var typeLabel: String {
        switch type {
        case "Image":
            let subtype = mime.split(separator: "/").last.map(String.init) ?? ""
            return subtype.isEmpty ? "image" : subtype
        case "XHR": return "xhr"
        case "WebSocket": return "websocket"
        case "EventSource": return "eventsource"
        case "CSPViolationReport": return "csp-report"
        default: return type.lowercased()
        }
    }

    var statusLabel: String {
        if canceled { return "(canceled)" }
        if let blockedReason { return "(blocked:\(blockedReason))" }
        if failure != nil { return "(failed)" }
        if type == "WebSocket", let status { return status == 101 ? "101" : "\(status)" }
        guard let status else { return isFinished ? "" : "(pending)" }
        return "\(status)"
    }

    var sizeLabel: String {
        if let cache { return "(\(cache))" }
        if failure != nil, transferred == 0 { return "0 B" }
        if !isFinished, transferred == 0 { return "" }
        return Format.bytes(transferred)
    }

    var duration: Double? { end.map { $0 - start } }

    var initiatorLabel: String {
        guard let initiator else { return "" }
        if let frame = initiator.obj("stack")?.list("callFrames").first(where: { !($0.str("url") ?? "").isEmpty }) {
            return "\(Self.short(frame.str("url") ?? "")):\((frame.int("lineNumber") ?? 0) + 1)"
        }
        if let url = initiator.str("url"), !url.isEmpty {
            let line = initiator.int("lineNumber").map { ":\($0 + 1)" } ?? ""
            return Self.short(url) + line
        }
        switch initiator.str("type") {
        case "preflight": return "Preflight"
        case "redirect": return "Redirect"
        case "parser": return "Parser"
        case "script": return "Script"
        default: return "Other"
        }
    }

    static func short(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        let name = (parts.path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? (parts.host ?? url) : name
    }

    var sentHeaders: [(name: String, value: String)] { rawRequestHeaders ?? requestHeaders }
    var receivedHeaders: [(name: String, value: String)] { rawResponseHeaders ?? responseHeaders }

    func header(_ name: String, in headers: [(name: String, value: String)]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct NetFrame {
    let sent: Bool
    let time: Double
    let opcode: Int
    let data: String
}

@MainActor
final class NetworkModel: InspectorModel {
    private weak var session: InspectorSession?
    private(set) var requests: [NetRequest] = []
    private var byID: [String: NetRequest] = [:]
    private var pendingRequestHeaders: [String: [(name: String, value: String)]] = [:]
    private var pendingResponse: [String: JSON] = [:]
    private var bodies: [String: (text: String, base64: Bool)] = [:]
    private var redirects = 0
    let changed = Signal<Void>()

    var recording = true {
        didSet { changed.send() }
    }
    var preservesLog = false {
        didSet { changed.send() }
    }
    var cacheDisabled: Bool {
        get { session?.developerState?().cacheDisabled ?? false }
        set {
            session?.updateDeveloperState? { $0.cacheDisabled = newValue }
            changed.send()
        }
    }
    var throttle: NetworkPreset {
        get { session?.developerState?().network ?? .unthrottled }
        set {
            session?.updateDeveloperState? { $0.network = newValue }
            changed.send()
        }
    }
    private(set) var blocked: [String] = []

    private(set) var navigationStart: Double?
    private(set) var domContentLoaded: Double?
    private(set) var loaded: Double?
    private(set) var latest: Double = 0

    static let limit = 3000

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session else { return }
        session.on("Network.", self) { [weak self] method, params in self?.handle(method, params) }
        session.on("Page.frameNavigated", self) { [weak self] _, params in self?.navigated(params) }
        session.on("Page.domContentEventFired", self) { [weak self] _, params in
            self?.domContentLoaded = params.num("timestamp")
            self?.changed.send()
        }
        session.on("Page.loadEventFired", self) { [weak self] _, params in
            self?.loaded = params.num("timestamp")
            self?.changed.send()
        }
        session.call("Network.enable", ["maxTotalBufferSize": 200_000_000, "maxResourceBufferSize": 50_000_000,
                                        "maxPostDataSize": 1_000_000])
    }

    func stop() {
        if !blocked.isEmpty { session?.call("Network.setBlockedURLs", ["urls": [String]()]) }
    }

    func clear() {
        requests = []
        byID = [:]
        bodies = [:]
        pendingRequestHeaders = [:]
        pendingResponse = [:]
        navigationStart = nil
        domContentLoaded = nil
        loaded = nil
        changed.send()
    }

    func block(_ pattern: String) {
        guard !blocked.contains(pattern) else { return }
        blocked.append(pattern)
        session?.call("Network.setBlockedURLs", ["urls": blocked])
        changed.send()
    }

    func unblock(_ pattern: String? = nil) {
        if let pattern { blocked.removeAll { $0 == pattern } } else { blocked = [] }
        session?.call("Network.setBlockedURLs", ["urls": blocked])
        changed.send()
    }

    func replay(_ request: NetRequest) {
        session?.call("Network.replayXHR", ["requestId": request.requestID])
    }

    func clearBrowserCache() {
        session?.call("Network.clearBrowserCache")
    }

    func body(of request: NetRequest) async -> (text: String, base64: Bool)? {
        if let body = bodies[request.key] { return body }
        guard !request.isRedirect, request.type != "WebSocket", let session,
              let result = try? await session.send("Network.getResponseBody", ["requestId": request.requestID]) else { return nil }
        let body = (result.str("body") ?? "", result.bool("base64Encoded"))
        bodies[request.key] = body
        return body
    }

    func postData(of request: NetRequest) async -> String? {
        if let data = request.postData { return data }
        guard request.hasPostData, let session,
              let result = try? await session.send("Network.getRequestPostData", ["requestId": request.requestID]) else { return nil }
        request.postData = result.str("postData")
        return request.postData
    }

    static func headers(_ object: JSON?) -> [(name: String, value: String)] {
        guard let object else { return [] }
        var headers: [(name: String, value: String)] = []
        for (name, value) in object {
            for line in "\(value)".split(separator: "\n", omittingEmptySubsequences: false) {
                headers.append((name, String(line)))
            }
        }
        return headers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func handle(_ method: String, _ params: JSON) {
        guard let id = params.str("requestId") else { return }
        let time = params.num("timestamp")
        if let time { latest = max(latest, time) }
        let request = byID[id]
        switch method {
        case "Network.requestWillBeSent":
            willBeSend(id, params, at: time ?? latest)
        case "Network.requestWillBeSentExtraInfo":
            let headers = Self.headers(params.obj("headers"))
            if let request { request.rawRequestHeaders = headers } else { pendingRequestHeaders[id] = headers }
        case "Network.responseReceived":
            guard let request, let response = params.obj("response") else { return }
            if let type = params.str("type") { request.type = type }
            apply(response, to: request, at: time ?? latest)
        case "Network.responseReceivedExtraInfo":
            if let request { applyExtra(params, to: request) } else { pendingResponse[id] = params }
        case "Network.dataReceived":
            guard let request else { return }
            request.resourceSize += params.num("dataLength") ?? 0
            if let encoded = params.num("encodedDataLength"), encoded > 0 { request.transferred += encoded }
        case "Network.loadingFinished":
            guard let request else { return }
            request.end = time ?? latest
            if let encoded = params.num("encodedDataLength"), encoded > 0 || request.cache == nil {
                request.transferred = encoded
            }
        case "Network.loadingFailed":
            guard let request else { return }
            request.end = time ?? latest
            request.failure = params.str("errorText") ?? "Failed"
            request.canceled = params.bool("canceled")
            request.blockedReason = params.str("blockedReason")
            if let type = params.str("type") { request.type = type }
        case "Network.requestServedFromCache":
            request?.cache = "memory cache"
        case "Network.webSocketCreated":
            guard recording else { return }
            let entry = NetRequest(requestID: id, loaderID: "", url: params.str("url") ?? "", method: "GET",
                                   type: "WebSocket", start: latest, wallTime: Date().timeIntervalSince1970)
            entry.initiator = params.obj("initiator")
            add(entry)
        case "Network.webSocketWillSendHandshakeRequest":
            request?.requestHeaders = Self.headers(params.obj("request")?.obj("headers"))
        case "Network.webSocketHandshakeResponseReceived":
            guard let request, let response = params.obj("response") else { return }
            request.status = response.int("status")
            request.statusText = response.str("statusText") ?? ""
            request.responseHeaders = Self.headers(response.obj("headers"))
            request.responseTime = time
        case "Network.webSocketFrameSent", "Network.webSocketFrameReceived":
            guard let request, let response = params.obj("response") else { return }
            request.frames.append(NetFrame(sent: method.hasSuffix("Sent"), time: time ?? latest,
                                           opcode: response.int("opcode") ?? 1, data: response.str("payloadData") ?? ""))
            request.transferred += Double(response.str("payloadData")?.utf8.count ?? 0)
        case "Network.webSocketFrameError":
            request?.frames.append(NetFrame(sent: false, time: time ?? latest, opcode: -1, data: params.str("errorMessage") ?? ""))
        case "Network.webSocketClosed":
            request?.end = time ?? latest
        case "Network.eventSourceMessageReceived":
            guard let request else { return }
            let name = params.str("eventName").map { $0 == "message" || $0.isEmpty ? "" : "\($0): " } ?? ""
            request.frames.append(NetFrame(sent: false, time: time ?? latest, opcode: 0, data: name + (params.str("data") ?? "")))
        default:
            return
        }
        request?.version += 1
        changed.send()
    }

    private func willBeSend(_ id: String, _ params: JSON, at time: Double) {
        let request = params.obj("request") ?? [:]
        if let redirect = params.obj("redirectResponse"), let previous = byID[id] {
            apply(redirect, to: previous, at: time)
            previous.end = time
            previous.isRedirect = true
            previous.transferred = max(previous.transferred, redirect.num("encodedDataLength") ?? 0)
            redirects += 1
            previous.key = "\(id):redirect\(redirects)"
            previous.version += 1
            byID[id] = nil
        }
        guard recording else { return }
        let entry = NetRequest(requestID: id, loaderID: params.str("loaderId") ?? "", url: request.str("url") ?? "",
                               method: request.str("method") ?? "GET", type: params.str("type") ?? "Other",
                               start: time, wallTime: params.num("wallTime") ?? Date().timeIntervalSince1970)
        entry.requestHeaders = Self.headers(request.obj("headers"))
        entry.postData = request.str("postData")
        entry.hasPostData = request.bool("hasPostData") || entry.postData != nil
        entry.referrerPolicy = request.str("referrerPolicy")
        entry.initiator = params.obj("initiator")
        if let headers = pendingRequestHeaders.removeValue(forKey: id) { entry.rawRequestHeaders = headers }
        add(entry)
    }

    private func add(_ entry: NetRequest) {
        requests.append(entry)
        byID[entry.requestID] = entry
        if requests.count > Self.limit {
            let removed = requests.prefix(requests.count - Self.limit + Self.limit / 10)
            for old in removed where byID[old.requestID] === old {
                byID[old.requestID] = nil
                bodies[old.key] = nil
            }
            requests.removeFirst(removed.count)
        }
        if pendingRequestHeaders.count > 200 { pendingRequestHeaders = [:] }
        if pendingResponse.count > 200 { pendingResponse = [:] }
    }

    private func apply(_ response: JSON, to request: NetRequest, at time: Double) {
        request.status = response.int("status")
        request.statusText = response.str("statusText") ?? ""
        request.mime = response.str("mimeType") ?? request.mime
        request.responseHeaders = Self.headers(response.obj("headers"))
        request.responseHeadersText = response.str("headersText") ?? request.responseHeadersText
        request.timing = response.obj("timing")
        if let ip = response.str("remoteIPAddress"), !ip.isEmpty {
            let host = ip.contains(":") ? "[\(ip)]" : ip
            request.remoteAddress = response.int("remotePort").map { "\(host):\($0)" } ?? host
        }
        request.protocolName = response.str("protocol")
        if response.bool("fromDiskCache") { request.cache = "disk cache" }
        if response.bool("fromPrefetchCache") { request.cache = "prefetch cache" }
        if response.bool("fromServiceWorker") { request.cache = "ServiceWorker" }
        request.transferred = max(request.transferred, response.num("encodedDataLength") ?? 0)
        request.responseTime = time
        if let extra = pendingResponse.removeValue(forKey: request.requestID) { applyExtra(extra, to: request) }
    }

    private func applyExtra(_ params: JSON, to request: NetRequest) {
        request.rawResponseHeaders = Self.headers(params.obj("headers"))
        if let text = params.str("headersText") { request.responseHeadersText = text }
    }

    private func navigated(_ params: JSON) {
        guard let frame = params.obj("frame"), frame["parentId"] == nil else { return }
        let loader = frame.str("loaderId") ?? ""
        domContentLoaded = nil
        loaded = nil
        navigationStart = requests.last { $0.loaderID == loader && $0.type == "Document" }?.start ?? latest
        if !preservesLog {
            requests.removeAll { $0.loaderID != loader && $0.type != "WebSocket" || $0.type == "WebSocket" && $0.isFinished }
            byID = byID.filter { entry in requests.contains { $0 === entry.value } }
            let keys = Set(requests.map(\.key))
            bodies = bodies.filter { keys.contains($0.key) }
        }
        changed.send()
    }
}

@MainActor
private enum NetKind: Int, CaseIterable {
    case all, fetch, document, css, script, font, image, media, manifest, socket, wasm, other

    var title: String {
        switch self {
        case .all: "All"
        case .fetch: "Fetch/XHR"
        case .document: "Doc"
        case .css: "CSS"
        case .script: "JS"
        case .font: "Font"
        case .image: "Img"
        case .media: "Media"
        case .manifest: "Manifest"
        case .socket: "WS"
        case .wasm: "Wasm"
        case .other: "Other"
        }
    }

    static func of(_ request: NetRequest) -> Self {
        if request.mime == "application/wasm" { return .wasm }
        switch request.type {
        case "Fetch", "XHR": return .fetch
        case "Document": return .document
        case "Stylesheet": return .css
        case "Script": return .script
        case "Font": return .font
        case "Image": return .image
        case "Media": return .media
        case "Manifest": return .manifest
        case "WebSocket": return .socket
        default: return .other
        }
    }
}

final class NetworkPanel: InspectorPanelView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var model: NetworkModel?
    private let toolbar = InspectorToolbar()
    private let typeBar = InspectorToolbar()
    private let record = InspectorButton("record.circle", tip: "Record network log")
    private let clearButton = InspectorButton("nosign", tip: "Clear")
    private let filter = InspectorFilterField(placeholder: "Filter (-text hides)")
    private let preserve = InspectorButton("pin", tip: "Preserve log across page loads")
    private let noCache = InspectorButton("externaldrive.badge.xmark", tip: "Disable cache")
    private let throttleButton = InspectorButton("speedometer", tip: "Throttling")
    private let blockedButton = InspectorButton("hand.raised", tip: "Blocked requests")
    private let types = InspectorChips(NetKind.allCases.map(\.title))
    private let typesScroll = NSScrollView()
    private let table = InspectorTableView()
    private var tableScroll: NSScrollView!
    private let listPane = FlippedView()
    private let empty = InspectorEmptyView("Recording network activity…\nReload the page to see all of its requests.")
    private let detail = RequestDetailView()
    private var split: InspectorSplitView!
    private let footer = FooterBar()
    private lazy var reloader = Coalescer(delay: 0.1) { [weak self] in self?.reload() }

    private var rows: [NetRequest] = []
    private var selectedKey: String?
    private var reloading = false
    private var query = ""
    private var kinds: Set<NetKind> = [.all]
    private var sortKey = ""
    private var ascending = true

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Name", 150), ("status", "Status", 44), ("type", "Type", 60), ("initiator", "Initiator", 100),
        ("size", "Size", 56), ("time", "Time", 52), ("waterfall", "Waterfall", 80),
    ]
    private static let hiddenKey = "inspector.network.hiddenColumns"

    override init(frame: NSRect) {
        super.init(frame: frame)
        record.onColor = .systemRed
        record.action = { [weak self] in self?.model?.recording.toggle() }
        clearButton.action = { [weak self] in self?.model?.clear() }
        filter.onChange = { [weak self] text in
            self?.query = text
            self?.reloader.flush()
        }
        preserve.action = { [weak self] in self?.model?.preservesLog.toggle() }
        noCache.action = { [weak self] in self?.model?.cacheDisabled.toggle() }
        throttleButton.onColor = .systemOrange
        throttleButton.action = { [weak self] in self?.showThrottleMenu() }
        blockedButton.onColor = .systemRed
        blockedButton.action = { [weak self] in self?.showBlockedMenu() }
        toolbar.add(record, width: 24)
        toolbar.add(clearButton, width: 24)
        toolbar.addSeparator()
        toolbar.add(filter, width: nil)
        toolbar.add(preserve, width: 24)
        toolbar.add(noCache, width: 24)
        toolbar.add(throttleButton, width: 24)
        toolbar.add(blockedButton, width: 24)

        types.multiple = true
        types.onChange = { [weak self] selection in
            self?.kinds = Set(selection.compactMap(NetKind.init(rawValue:)))
            self?.reloader.flush()
        }
        typesScroll.documentView = types
        typesScroll.drawsBackground = false
        typesScroll.hasHorizontalScroller = false
        typesScroll.hasVerticalScroller = false
        typesScroll.verticalScrollElasticity = .none
        typeBar.add(typesScroll, width: nil)

        tableScroll = InspectorTable.make(table, columns: Self.columns)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.tableColumns.first?.minWidth = 80
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.menuForRow = { [weak self] row in self?.menu(for: row) }
        table.onKey = { [weak self] event in self?.key(event) ?? false }
        for column in table.tableColumns {
            column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
        }
        let hidden = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? ["initiator"]
        for column in table.tableColumns { column.isHidden = hidden.contains(column.identifier.rawValue) }
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        listPane.addSubview(tableScroll)
        listPane.addSubview(empty)

        detail.onClose = { [weak self] in self?.closeDetail() }
        split = InspectorSplitView(listPane, detail, vertical: false, key: "network", fraction: 0.45, minimum: 60)
        split.setSecondCollapsed(true)

        for view in [toolbar, typeBar, split!, footer] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        typeBar.frame = NSRect(x: 0, y: toolbar.frame.maxY, width: bounds.width, height: 26)
        types.frame = NSRect(x: 0, y: 0, width: types.preferredWidth, height: 20)
        let footerHeight: CGFloat = 22
        split.frame = NSRect(x: 0, y: typeBar.frame.maxY, width: bounds.width,
                             height: max(bounds.height - typeBar.frame.maxY - footerHeight, 0))
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        split.layoutSubtreeIfNeeded()
        tableScroll.frame = listPane.bounds
        tableScroll.autoresizingMask = [.width, .height]
        fitNameColumn()
        empty.frame = listPane.bounds
        empty.autoresizingMask = [.width, .height]
    }

    override func sessionChanged() {
        model?.changed.stopObserving(self)
        model = session?.model(NetworkModel.self)
        model?.changed.observe(self) { [weak self] in
            guard let self, isShown else { return }
            reloader.schedule()
        }
        detail.session = session
        detail.model = model
        closeDetail()
        reloader.flush()
    }

    override func panelDidAppear() { reloader.flush() }

    override func focusFilter() { window?.makeFirstResponder(filter) }

    override func cancelOperation(_ sender: Any?) { closeDetail() }

    private func matches(_ request: NetRequest) -> Bool {
        if !kinds.contains(.all), !kinds.contains(NetKind.of(request)) { return false }
        for word in query.split(separator: " ") {
            if word.hasPrefix("-"), word.count > 1 {
                if request.url.localizedCaseInsensitiveContains(word.dropFirst()) { return false }
            } else if !request.url.localizedCaseInsensitiveContains(word) {
                return false
            }
        }
        return true
    }

    private func sorted(_ requests: [NetRequest]) -> [NetRequest] {
        guard !sortKey.isEmpty else { return requests }
        let order: (NetRequest, NetRequest) -> Bool = switch sortKey {
        case "name": { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case "status": { ($0.status ?? -1) < ($1.status ?? -1) }
        case "type": { $0.typeLabel < $1.typeLabel }
        case "initiator": { $0.initiatorLabel < $1.initiatorLabel }
        case "size": { $0.transferred < $1.transferred }
        case "time": { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        default: { $0.start < $1.start }
        }
        return requests.sorted { ascending ? order($0, $1) : order($1, $0) }
    }

    private func reload() {
        guard let model else {
            rows = []
            table.reloadData()
            footer.text = ""
            return
        }
        rows = sorted(model.requests.filter(matches))
        let clip = tableScroll.contentView
        let atBottom = clip.bounds.maxY >= table.bounds.height - 4
        reloading = true
        table.reloadData()
        if let key = selectedKey, let row = rows.firstIndex(where: { $0.key == key }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
            if selectedKey != nil, !model.requests.contains(where: { $0.key == selectedKey }) { closeDetail() }
        }
        reloading = false
        if atBottom, sortKey.isEmpty, !rows.isEmpty, table.selectedRow < 0 { table.scrollRowToVisible(rows.count - 1) }
        empty.isHidden = !model.requests.isEmpty
        record.isOn = model.recording
        preserve.isOn = model.preservesLog
        noCache.isOn = model.cacheDisabled
        throttleButton.isOn = model.throttle != .unthrottled
        throttleButton.toolTip = "Throttling: \(model.throttle.title)"
        blockedButton.isOn = !model.blocked.isEmpty
        blockedButton.isHidden = model.blocked.isEmpty
        toolbar.needsLayout = true
        updateFooter(model)
        detail.refresh()
    }

    private func updateFooter(_ model: NetworkModel) {
        let all = model.requests
        var parts: [String] = []
        parts.append(rows.count == all.count ? "\(all.count) requests" : "\(rows.count) / \(all.count) requests")
        let transferred = rows.reduce(0) { $0 + ($1.cache == nil ? $1.transferred : 0) }
        let resources = rows.reduce(0) { $0 + max($1.resourceSize, $1.cache == nil ? 0 : $1.resourceSize) }
        parts.append("\(Format.bytes(transferred)) transferred")
        if resources > 0 { parts.append("\(Format.bytes(resources)) resources") }
        if let first = model.navigationStart ?? all.first?.start {
            if let last = all.compactMap(\.end).max(), last > first { parts.append("Finish: \(Format.duration(last - first))") }
            if let dcl = model.domContentLoaded, dcl > first { parts.append("DOMContentLoaded: \(Format.duration(dcl - first))") }
            if let load = model.loaded, load > first { parts.append("Load: \(Format.duration(load - first))") }
        }
        footer.text = parts.joined(separator: " · ")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let request = rows[row]
        let color: NSColor = request.isFailed ? InspectorTheme.error : .labelColor
        let secondary: NSColor = request.isFailed ? InspectorTheme.error : .secondaryLabelColor
        switch column {
        case "name":
            let text = NSMutableAttributedString()
            if request.isRedirect || (300..<400).contains(request.status ?? 0) {
                text.add("↪ ", .tertiaryLabelColor, font: InspectorTheme.font)
            }
            text.add(request.displayName, color, font: InspectorTheme.font)
            let cell = InspectorTable.cell(tableView, "name", text)
            cell.toolTip = request.url
            return cell
        case "status":
            return InspectorTable.cell(tableView, "status", request.statusLabel, color: request.status == nil ? secondary : color)
        case "type":
            return InspectorTable.cell(tableView, "type", request.typeLabel, color: secondary)
        case "initiator":
            return InspectorTable.cell(tableView, "initiator", request.initiatorLabel, color: InspectorTheme.link)
        case "size":
            return InspectorTable.cell(tableView, "size", request.sizeLabel, color: secondary)
        case "time":
            let text = request.duration.map(Format.duration) ?? (request.failure == nil ? "Pending" : "")
            return InspectorTable.cell(tableView, "time", text, color: secondary)
        case "waterfall":
            let identifier = NSUserInterfaceItemIdentifier("cell.waterfall")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? WaterfallCell ?? {
                let cell = WaterfallCell()
                cell.identifier = identifier
                return cell
            }()
            let (from, to) = span()
            let length = max(to - from, 0.001)
            cell.start = CGFloat((request.start - from) / length)
            cell.response = request.responseTime.map { CGFloat(($0 - from) / length) }
            cell.end = CGFloat(((request.end ?? model?.latest ?? request.start) - from) / length)
            cell.failed = request.isFailed
            cell.needsDisplay = true
            return cell
        default:
            return nil
        }
    }

    private func span() -> (Double, Double) {
        guard let model, let first = model.requests.first?.start else { return (0, 1) }
        let start = min(model.navigationStart ?? first, first)
        let end = max(model.latest, model.requests.compactMap(\.end).max() ?? start)
        return (start, end)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }

    private func fitNameColumn() {
        guard let name = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
        let spacing = table.intercellSpacing.width
        let others = table.tableColumns.filter { !$0.isHidden && $0 !== name }.reduce(0) { $0 + $1.width + spacing }
        let width = max(tableScroll.contentSize.width - others - spacing - 2, name.minWidth)
        if abs(name.width - width) > 0.5 { name.width = width }
    }

    override func selectRow(_ row: Int) {
        guard row < table.numberOfRows else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return }
        selectedKey = rows[row].key
        split.setSecondCollapsed(false)
        detail.show(rows[row])
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let descriptor = tableView.sortDescriptors.first
        sortKey = descriptor?.key ?? ""
        ascending = descriptor?.ascending ?? true
        reloader.flush()
    }

    private func closeDetail() {
        selectedKey = nil
        reloading = true
        table.deselectAll(nil)
        reloading = false
        split.setSecondCollapsed(true)
        detail.show(nil)
    }

    private func key(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            closeDetail()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", table.selectedRow >= 0 {
            Format.copy(rows[table.selectedRow].url)
            return true
        }
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in table.tableColumns where column.identifier.rawValue != "name" {
            menu.add(column.title, state: !column.isHidden) { [weak self] in
                column.isHidden.toggle()
                self?.saveHiddenColumns()
                self?.fitNameColumn()
            }
        }
    }

    private func saveHiddenColumns() {
        UserDefaults.standard.set(table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue), forKey: Self.hiddenKey)
    }

    private func showThrottleMenu() {
        guard let model else { return }
        let menu = NSMenu()
        for preset in NetworkPreset.allCases {
            menu.add(preset.title, state: model.throttle == preset) { [weak model] in model?.throttle = preset }
        }
        throttleButton.popUp(menu)
    }

    private func showBlockedMenu() {
        guard let model else { return }
        let menu = NSMenu()
        for pattern in model.blocked {
            menu.add("Unblock \(pattern.clipped(60))") { [weak model] in model?.unblock(pattern) }
        }
        menu.addItem(.separator())
        menu.add("Unblock All") { [weak model] in model?.unblock() }
        blockedButton.popUp(menu)
    }

    private func menu(for row: Int) -> NSMenu? {
        guard let model, row < rows.count else { return nil }
        let request = rows[row]
        let menu = NSMenu()
        if let open = session?.openTab, request.url.hasPrefix("http") || request.url.hasPrefix("file") {
            menu.add("Open in New Tab") { open(request.url) }
            menu.addItem(.separator())
        }
        menu.add("Copy URL") { Format.copy(request.url) }
        menu.add("Copy as cURL") { [weak model] in
            Task { Format.copy(NetCopy.curl(request, body: await model?.postData(of: request))) }
        }
        menu.add("Copy as fetch") { [weak model] in
            Task { Format.copy(NetCopy.fetch(request, body: await model?.postData(of: request))) }
        }
        menu.add("Copy Response", enabled: request.isFinished && request.failure == nil) { [weak model] in
            Task {
                guard let body = await model?.body(of: request) else { return }
                Format.copy(body.base64 ? (Data(base64Encoded: body.text).flatMap { String(data: $0, encoding: .utf8) } ?? body.text) : body.text)
            }
        }
        menu.add("Copy Request Headers") { Format.copy(NetCopy.headers(request.sentHeaders)) }
        menu.add("Copy Response Headers", enabled: !request.receivedHeaders.isEmpty) {
            Format.copy(request.responseHeadersText ?? NetCopy.headers(request.receivedHeaders))
        }
        menu.addItem(.separator())
        if request.type == "XHR" {
            menu.add("Replay XHR") { [weak model] in model?.replay(request) }
        }
        let pattern = request.url
        if model.blocked.contains(pattern) {
            menu.add("Unblock Request URL") { [weak model] in model?.unblock(pattern) }
        } else {
            menu.add("Block Request URL") { [weak model] in model?.block(pattern) }
        }
        if !request.host.isEmpty {
            let domain = "*://\(request.host)/*"
            if model.blocked.contains(domain) {
                menu.add("Unblock Request Domain") { [weak model] in model?.unblock(domain) }
            } else {
                menu.add("Block Request Domain") { [weak model] in model?.block(domain) }
            }
        }
        menu.addItem(.separator())
        menu.add("Clear Browser Cache") { [weak model] in model?.clearBrowserCache() }
        menu.add("Clear Network Log") { [weak model] in model?.clear() }
        return menu
    }
}

@MainActor
private enum NetCopy {
    static func headers(_ headers: [(name: String, value: String)]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func curl(_ request: NetRequest, body: String?) -> String {
        var lines = ["curl \(quote(request.url))"]
        if request.method != "GET" || body != nil, request.method != (body == nil ? "GET" : "POST") {
            lines.append("-X \(quote(request.method))")
        }
        for header in request.sentHeaders where !header.name.hasPrefix(":") {
            lines.append("-H \(quote("\(header.name): \(header.value)"))")
        }
        if let body { lines.append("--data-raw \(quote(body))") }
        return lines.joined(separator: " \\\n  ")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func fetch(_ request: NetRequest, body: String?) -> String {
        let skipped: Set = ["host", "connection", "content-length", "cookie", "user-agent", "referer", "accept-encoding"]
        let headers = request.sentHeaders.filter { !$0.name.hasPrefix(":") && !skipped.contains($0.name.lowercased()) }
        var lines = ["fetch(\(json(request.url)), {"]
        var options: [String] = []
        if !headers.isEmpty {
            let entries = headers.map { "    \(json($0.name.lowercased())): \(json($0.value))" }.joined(separator: ",\n")
            options.append("  \"headers\": {\n\(entries)\n  }")
        }
        if let referrer = request.header("referer", in: request.sentHeaders) { options.append("  \"referrer\": \(json(referrer))") }
        options.append("  \"body\": \(body.map(json) ?? "null")")
        options.append("  \"method\": \(json(request.method))")
        options.append("  \"mode\": \"cors\"")
        options.append("  \"credentials\": \"include\"")
        lines.append(options.joined(separator: ",\n"))
        lines.append("});")
        return lines.joined(separator: "\n")
    }
}

private final class WaterfallCell: NSView {
    var start: CGFloat = 0
    var response: CGFloat?
    var end: CGFloat = 0
    var failed = false

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width - 4
        let height: CGFloat = 8
        let y = (bounds.height - height) / 2
        let x0 = 2 + min(max(start, 0), 1) * width
        let x1 = max(2 + min(max(end, 0), 1) * width, x0 + 2)
        let xr = response.map { min(max(2 + $0 * width, x0), x1) } ?? x1
        let color: NSColor = failed ? .systemRed : .systemBlue
        if xr > x0 {
            (failed ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.55).setFill()
            NSRect(x: x0, y: y, width: xr - x0, height: height).fill()
        }
        if x1 > xr {
            color.setFill()
            NSRect(x: xr, y: y, width: x1 - xr, height: height).fill()
        }
    }
}

private final class FooterBar: FlippedView {
    private let label = Label.make("", size: 11, color: .secondaryLabelColor)
    private let line = CALayer()

    var text: String {
        get { label.stringValue }
        set { label.setIfChanged(newValue); label.toolTip = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: (bounds.height - 15) / 2, width: bounds.width - 16, height: 15)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func updateLayer() {
        layer?.backgroundColor = InspectorTheme.bar.cgColor
        line.backgroundColor = InspectorTheme.separator.cgColor
    }
}

private enum DetailTab: String {
    case headers = "Headers", payload = "Payload", preview = "Preview", response = "Response"
    case initiator = "Initiator", timing = "Timing", messages = "Messages", cookies = "Cookies"
}

private final class LocationNode: ValueNode {
    let url: String
    let line: Int
    let column: Int

    init(name: String, url: String, line: Int, column: Int) {
        self.url = url
        self.line = line
        self.column = column
        super.init(name: name)
    }

    override func valueText() -> NSAttributedString {
        NSMutableAttributedString().add("\(NetRequest.short(url)):\(line + 1)", InspectorTheme.link)
    }

    override var copyText: String { "\(url):\(line + 1):\(column + 1)" }
}

private final class RequestDetailView: FlippedView {
    weak var session: InspectorSession?
    weak var model: NetworkModel?
    var onClose: (() -> Void)?
    private(set) var request: NetRequest?
    private var shownVersion = -1
    private var tab = DetailTab.headers
    private var tabs: [DetailTab] = []

    private let bar = InspectorToolbar()
    private var chips = InspectorChips([])
    private let chipsHost = FlippedView()
    private let pretty = InspectorButton("curlybraces", tip: "Pretty-print")
    private let close = InspectorButton("xmark", tip: "Close  ⎋")
    private let content = FlippedView()
    private let tree = ValueTreeView()
    private let code = CodeView()
    private let imageScroll = NSScrollView()
    private let image = NSImageView()
    private let timing = TimingView()
    private let timingScroll = NSScrollView()
    private let frames = FramesTable()
    private let message = InspectorEmptyView("")
    private var body: (text: String, base64: Bool)?
    private var bodyKey: String?
    private var prettyPrinted = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.add(chipsHost, width: nil)
        bar.add(pretty, width: 24)
        bar.add(close, width: 24)
        close.action = { [weak self] in self?.onClose?() }
        pretty.isOn = true
        pretty.action = { [weak self] in
            guard let self else { return }
            prettyPrinted.toggle()
            pretty.isOn = prettyPrinted
            render()
        }
        addSubview(bar)
        addSubview(content)
        tree.outline.target = self
        tree.outline.action = #selector(treeClicked)
        code.wraps = true
        image.imageScaling = .scaleProportionallyDown
        imageScroll.documentView = image
        imageScroll.drawsBackground = false
        imageScroll.hasVerticalScroller = true
        imageScroll.autohidesScrollers = true
        timingScroll.documentView = timing
        timingScroll.drawsBackground = false
        timingScroll.hasVerticalScroller = true
        timingScroll.autohidesScrollers = true
        for view in [tree, code, imageScroll, timingScroll, frames.scroll, message] as [NSView] {
            view.isHidden = true
            content.addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        content.frame = NSRect(x: 0, y: bar.frame.maxY, width: bounds.width, height: max(bounds.height - bar.frame.maxY, 0))
        chips.frame = NSRect(x: 0, y: 0, width: chips.preferredWidth, height: 22)
        for view in content.subviews { view.frame = content.bounds }
        let size = image.image?.size ?? .zero
        let fit = min(1, size.width > 0 ? (content.bounds.width - 24) / size.width : 1)
        image.frame = NSRect(x: 0, y: 0, width: max(content.bounds.width - 2, 0), height: max(size.height * fit + 24, content.bounds.height - 2))
        timing.frame = NSRect(x: 0, y: 0, width: max(content.bounds.width - 2, 0), height: max(timing.contentHeight, content.bounds.height - 2))
    }

    func show(_ request: NetRequest?) {
        guard request !== self.request else { return }
        self.request = request
        body = nil
        bodyKey = nil
        shownVersion = -1
        refresh()
    }

    func refresh() {
        guard let request else { return }
        guard request.version != shownVersion else { return }
        shownVersion = request.version
        var available: [DetailTab] = [.headers]
        let hasQuery = !(URLComponents(string: request.url)?.queryItems ?? []).isEmpty
        if hasQuery || request.hasPostData { available.append(.payload) }
        if request.type == "WebSocket" || request.type == "EventSource" {
            available.append(.messages)
        } else {
            available += [.preview, .response]
        }
        available += [.initiator, .timing]
        if request.header("cookie", in: request.sentHeaders) != nil || request.header("set-cookie", in: request.receivedHeaders) != nil {
            available.append(.cookies)
        }
        if available != tabs {
            tabs = available
            chips.removeFromSuperview()
            chips = InspectorChips(tabs.map(\.rawValue))
            chips.onChange = { [weak self] selection in
                guard let self, let index = selection.first, index < tabs.count else { return }
                tab = tabs[index]
                render()
            }
            chipsHost.addSubview(chips)
            needsLayout = true
        }
        if !tabs.contains(tab) { tab = .headers }
        chips.selected = [tabs.firstIndex(of: tab) ?? 0]
        render()
    }

    private func display(_ view: NSView) {
        for subview in content.subviews { subview.isHidden = subview !== view }
    }

    private func showMessage(_ text: String) {
        message.text = text
        display(message)
    }

    private func render() {
        guard let request else { return }
        pretty.isHidden = true
        switch tab {
        case .headers: renderHeaders(request)
        case .payload: renderPayload(request)
        case .preview, .response: renderBody(request)
        case .initiator: renderInitiator(request)
        case .timing:
            timing.show(request, latest: model?.latest ?? request.start)
            display(timingScroll)
            needsLayout = true
        case .messages:
            frames.show(request.frames, start: request.start)
            display(frames.scroll)
        case .cookies: renderCookies(request)
        }
        bar.needsLayout = true
    }

    private static func text(_ value: String, _ color: NSColor = .labelColor) -> NSAttributedString {
        NSMutableAttributedString().add(value, color)
    }

    private static func group(_ name: String, _ headers: [(name: String, value: String)]) -> GroupNode {
        GroupNode(name: "\(name) (\(headers.count))", children: headers.map { GroupNode(name: $0.name, value: text($0.value)) })
    }

    private func renderHeaders(_ request: NetRequest) {
        var general: [ValueNode] = [
            GroupNode(name: "Request URL", value: Self.text(request.url)),
            GroupNode(name: "Request Method", value: Self.text(request.method)),
        ]
        let status = request.status.map { "\($0) \(request.statusText)".trimmingCharacters(in: .whitespaces) }
            ?? request.failure ?? "Pending"
        general.append(GroupNode(name: "Status Code", value: Self.text(status, request.isFailed ? InspectorTheme.error : .labelColor)))
        if let address = request.remoteAddress { general.append(GroupNode(name: "Remote Address", value: Self.text(address))) }
        if let policy = request.referrerPolicy { general.append(GroupNode(name: "Referrer Policy", value: Self.text(policy))) }
        if let proto = request.protocolName { general.append(GroupNode(name: "Protocol", value: Self.text(proto))) }
        if let cache = request.cache { general.append(GroupNode(name: "Served From", value: Self.text(cache))) }
        var roots: [ValueNode] = [GroupNode(name: "General", children: general)]
        if !request.receivedHeaders.isEmpty { roots.append(Self.group("Response Headers", request.receivedHeaders)) }
        roots.append(Self.group(request.rawRequestHeaders == nil ? "Request Headers (provisional)" : "Request Headers",
                                request.sentHeaders))
        tree.showsNames = true
        tree.show(roots)
        tree.expandRoots()
        display(tree)
    }

    private func renderPayload(_ request: NetRequest) {
        let key = request.key
        var roots: [ValueNode] = []
        if let items = URLComponents(string: request.url)?.queryItems, !items.isEmpty {
            roots.append(GroupNode(name: "Query String Parameters (\(items.count))",
                                   children: items.map { GroupNode(name: $0.name, value: Self.text($0.value ?? "", InspectorTheme.string)) }))
        }
        tree.showsNames = true
        tree.show(roots)
        tree.expandRoots()
        display(tree)
        guard request.hasPostData else { return }
        Task { [weak self] in
            guard let self, let data = await model?.postData(of: request), self.request?.key == key, tab == .payload else { return }
            let type = request.header("content-type", in: request.sentHeaders) ?? ""
            var node: ValueNode
            if let json = try? JSONSerialization.jsonObject(with: Data(data.utf8), options: [.fragmentsAllowed]) {
                node = GroupNode(name: "Request Payload", children: [JSONValueNode(name: "", value: json)].flatMap { $0.children ?? [$0] })
            } else if type.contains("application/x-www-form-urlencoded") {
                var parts = URLComponents()
                parts.percentEncodedQuery = data.replacingOccurrences(of: "+", with: "%20")
                let items = parts.queryItems ?? []
                node = GroupNode(name: "Form Data (\(items.count))",
                                 children: items.map { GroupNode(name: $0.name, value: Self.text($0.value ?? "", InspectorTheme.string)) })
            } else {
                node = GroupNode(name: "Request Payload", children: [GroupNode(name: "", value: Self.text(data.clipped(20_000)))])
            }
            tree.show(roots + [node])
            tree.expandRoots()
        }
    }

    private func renderBody(_ request: NetRequest) {
        guard request.isFinished else { return showMessage("Waiting for the response…") }
        if request.failure != nil { return showMessage("This request failed: \(request.failure ?? "")") }
        if let body, bodyKey == request.key { return present(body, of: request) }
        showMessage("Loading…")
        let key = request.key
        Task { [weak self] in
            guard let self else { return }
            let body = await model?.body(of: request)
            guard self.request?.key == key else { return }
            guard let body else { return showMessage("This request has no response data available.") }
            self.body = body
            bodyKey = key
            if tab == .preview || tab == .response { present(body, of: request) }
        }
    }

    private func present(_ body: (text: String, base64: Bool), of request: NetRequest) {
        let data = body.base64 ? Data(base64Encoded: body.text) ?? Data() : Data(body.text.utf8)
        let text = body.base64 ? String(data: data, encoding: .utf8) : body.text
        let language = CodeLanguage.guess(mime: request.mime, url: request.url)
        if tab == .preview {
            if request.mime.hasPrefix("image/"), let picture = NSImage(data: data) {
                image.image = picture
                image.toolTip = "\(Int(picture.size.width)) × \(Int(picture.size.height)) · \(Format.bytes(Double(data.count)))"
                display(imageScroll)
                needsLayout = true
                return
            }
            if let text, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                let root = JSONValueNode(name: "", value: json)
                tree.showsNames = true
                tree.show(root.children ?? [root])
                if (root.children?.count ?? 0) <= 20 { tree.expandRoots() }
                display(tree)
                return
            }
        }
        guard let text else {
            return showMessage("\(request.mime.isEmpty ? "Binary data" : request.mime), \(Format.bytes(Double(data.count))).")
        }
        if text.isEmpty { return showMessage("This request has no response data available.") }
        var shown = text
        if tab == .response, language == .json {
            pretty.isHidden = false
            if prettyPrinted, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
               let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]) {
                shown = String(decoding: data, as: UTF8.self)
            }
        }
        code.show(shown, language: language)
        display(code)
    }

    private func renderInitiator(_ request: NetRequest) {
        guard let initiator = request.initiator else { return showMessage("No initiator.") }
        var roots: [ValueNode] = [GroupNode(name: "Type", value: Self.text(initiator.str("type") ?? "other"))]
        if let url = initiator.str("url"), !url.isEmpty {
            roots.append(LocationNode(name: "Source", url: url, line: initiator.int("lineNumber") ?? 0,
                                      column: initiator.int("columnNumber") ?? 0))
        }
        var stack = initiator.obj("stack")
        var title = "Stack"
        while let current = stack {
            let frames: [ValueNode] = current.list("callFrames").map { frame in
                let name = frame.str("functionName").flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)"
                return LocationNode(name: name, url: frame.str("url") ?? "", line: frame.int("lineNumber") ?? 0,
                                    column: frame.int("columnNumber") ?? 0)
            }
            if !frames.isEmpty { roots.append(GroupNode(name: title, children: frames)) }
            stack = current.obj("parent")
            title = current.obj("parent")?.str("description").map { "Async: \($0)" } ?? "Async"
        }
        tree.showsNames = true
        tree.show(roots)
        tree.expandRoots()
        display(tree)
    }

    private func renderCookies(_ request: NetRequest) {
        var roots: [ValueNode] = []
        if let header = request.header("cookie", in: request.sentHeaders) {
            let cookies = header.components(separatedBy: "; ").map { pair -> ValueNode in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return GroupNode(name: parts.first ?? "", value: Self.text(parts.count > 1 ? parts[1] : "", InspectorTheme.string))
            }
            roots.append(GroupNode(name: "Request Cookies (\(cookies.count))", children: cookies))
        }
        let setCookies = request.receivedHeaders.filter { $0.name.lowercased() == "set-cookie" }.map(\.value)
        if !setCookies.isEmpty {
            let cookies = setCookies.map { line -> ValueNode in
                let fields = line.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                let pair = (fields.first ?? "").split(separator: "=", maxSplits: 1).map(String.init)
                let attributes = fields.dropFirst().map { field -> ValueNode in
                    let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                    return GroupNode(name: parts.first ?? "", value: Self.text(parts.count > 1 ? parts[1] : "✓"))
                }
                return GroupNode(name: pair.first ?? "", value: Self.text(pair.count > 1 ? pair[1] : "", InspectorTheme.string),
                                 children: attributes)
            }
            roots.append(GroupNode(name: "Response Cookies (\(cookies.count))", children: cookies))
        }
        tree.showsNames = true
        tree.show(roots)
        tree.expandRoots()
        display(tree)
    }

    @objc private func treeClicked() {
        let row = tree.outline.clickedRow
        guard row >= 0, let node = tree.outline.item(atRow: row) as? LocationNode, !node.url.isEmpty else { return }
        session?.revealSource(url: node.url, line: node.line, column: node.column)
    }
}

private final class TimingView: FlippedView {
    private var phases: [(name: String, start: Double, end: Double, color: NSColor)] = []
    private var total: Double = 0
    private var origin: Double = 0
    private var note = ""
    var contentHeight: CGFloat { CGFloat(phases.count) * 22 + 60 }

    func show(_ request: NetRequest, latest: Double) {
        phases = []
        note = ""
        let start = request.start * 1000
        let end = (request.end ?? latest) * 1000
        origin = start
        total = max(end - start, 0)
        if let timing = request.timing, let requestTime = timing.num("requestTime") {
            let base = requestTime * 1000
            func at(_ key: String) -> Double? {
                guard let value = timing.num(key), value >= 0 else { return nil }
                return base + value
            }
            if base > start { phases.append(("Queueing", start, base, .systemGray)) }
            let firstActivity = at("dnsStart") ?? at("connectStart") ?? at("sendStart")
            if let first = firstActivity, first > base { phases.append(("Stalled", base, first, .systemGray)) }
            if let a = at("proxyStart"), let b = at("proxyEnd") { phases.append(("Proxy negotiation", a, b, .systemGray)) }
            if let a = at("dnsStart"), let b = at("dnsEnd") { phases.append(("DNS Lookup", a, b, .systemTeal)) }
            if let a = at("connectStart"), let b = at("connectEnd") { phases.append(("Initial connection", a, b, .systemOrange)) }
            if let a = at("sslStart"), let b = at("sslEnd") { phases.append(("SSL", a, b, .systemPurple)) }
            if let a = at("workerStart"), let b = at("workerReady") { phases.append(("ServiceWorker startup", a, b, .systemYellow)) }
            if let a = at("sendStart"), let b = at("sendEnd") { phases.append(("Request sent", a, max(b, a), .systemGray)) }
            if let a = at("sendEnd"), let b = at("receiveHeadersEnd") {
                phases.append(("Waiting for server response", a, b, .systemGreen))
                if end > b { phases.append(("Content Download", b, end, .systemBlue)) }
            }
        } else {
            note = request.cache.map { "Served from the \($0)." } ?? (request.isFinished ? "No timing information." : "Still loading.")
            if total > 0 { phases.append(("Total", start, end, .systemBlue)) }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelWidth: CGFloat = 170, valueWidth: CGFloat = 64
        let barX = labelWidth + 12, barWidth = max(bounds.width - barX - valueWidth - 12, 20)
        let scale = total > 0 ? Double(barWidth) / total : 0
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: Theme.font(11), .foregroundColor: NSColor.secondaryLabelColor]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: InspectorTheme.mono(10.5), .foregroundColor: NSColor.labelColor]
        var y: CGFloat = 10
        for phase in phases {
            (phase.name as NSString).draw(in: NSRect(x: 10, y: y + 2, width: labelWidth, height: 16), withAttributes: labelAttributes)
            let x = barX + CGFloat((phase.start - origin) * scale)
            let width = max(CGFloat((phase.end - phase.start) * scale), 1)
            phase.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 5, width: width, height: 10), xRadius: 2, yRadius: 2).fill()
            let value = Format.duration(max(phase.end - phase.start, 0) / 1000) as NSString
            let size = value.size(withAttributes: valueAttributes)
            value.draw(at: NSPoint(x: bounds.width - size.width - 10, y: y + 3), withAttributes: valueAttributes)
            y += 22
        }
        y += 6
        let summary = (note.isEmpty ? "Total: \(Format.duration(total / 1000))" : note) as NSString
        summary.draw(at: NSPoint(x: 10, y: y), withAttributes: [.font: Theme.font(11, .medium), .foregroundColor: NSColor.labelColor])
    }
}

@MainActor
private final class FramesTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = InspectorTableView()
    private(set) var scroll: NSScrollView!
    private var frames: [NetFrame] = []
    private var start: Double = 0

    override init() {
        super.init()
        scroll = InspectorTable.make(table, columns: [("data", "Data", 260), ("length", "Length", 60), ("time", "Time", 70)])
        table.dataSource = self
        table.delegate = self
        table.menuForRow = { [weak self] row in
            guard let self, row < frames.count else { return nil }
            let frame = frames[row]
            let menu = NSMenu()
            menu.add("Copy Message") { Format.copy(frame.data) }
            return menu
        }
    }

    func show(_ frames: [NetFrame], start: Double) {
        let grew = frames.count != self.frames.count
        self.frames = frames
        self.start = start
        table.reloadData()
        if grew, !frames.isEmpty { table.scrollRowToVisible(frames.count - 1) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { frames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < frames.count else { return nil }
        let frame = frames[row]
        switch tableColumn?.identifier.rawValue {
        case "data":
            let text = NSMutableAttributedString()
            switch frame.opcode {
            case -1: text.add("⚠ ", InspectorTheme.error).add(frame.data.oneLine.clipped(500), InspectorTheme.error)
            case 2: text.add(frame.sent ? "↑ " : "↓ ", frame.sent ? .systemGreen : .systemRed).add("Binary message", .secondaryLabelColor)
            case 8: text.add(frame.sent ? "↑ " : "↓ ", .secondaryLabelColor).add("Connection close", .secondaryLabelColor)
            default:
                text.add(frame.sent ? "↑ " : "↓ ", frame.sent ? .systemGreen : .systemRed).add(frame.data.oneLine.clipped(500))
            }
            let cell = InspectorTable.cell(tableView, "data", text)
            cell.toolTip = frame.data.clipped(2000)
            return cell
        case "length":
            return InspectorTable.cell(tableView, "length", "\(frame.data.utf8.count)", color: .secondaryLabelColor)
        default:
            return InspectorTable.cell(tableView, "time", Format.duration(max(frame.time - start, 0)), color: .secondaryLabelColor)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = InspectorRowView()
        if row < frames.count, frames[row].sent {
            view.fill = NSColor.systemGreen.withAlphaComponent(0.06)
        }
        return view
    }
}
