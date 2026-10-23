import AppKit

struct PerformanceSample {
    let time: Double
    let values: [String: Double]
}

struct TraceSummary: Sendable {
    struct Slice: Sendable {
        let category: String
        let milliseconds: Double
    }
    struct Task: Sendable {
        let start: Double
        let duration: Double
    }
    var duration: Double = 0
    var slices: [Slice] = []
    var longTasks: [Task] = []
    var fps: Double?
    var events = 0
}

struct CoverageEntry {
    let url: String
    let isCSS: Bool
    var total: Int
    var used: Int
    var unused: Int { max(total - used, 0) }
}

@MainActor
final class PerformanceModel: InspectorModel {
    enum TraceState: Equatable {
        case idle, starting, recording, stopping
        case reading(bytes: Int)
    }

    private weak var session: InspectorSession?
    let updated = Signal<Void>()
    let changed = Signal<Void>()
    private(set) var samples: [PerformanceSample] = []
    private var last: [String: Double]?
    private var timer: Timer?
    private var enabled = false

    private(set) var traceState = TraceState.idle
    private(set) var traceStarted: Date?
    private(set) var trace: Data?
    private(set) var traceSummary: TraceSummary?
    private(set) var traceSummarizing = false
    var traceURL: URL?
    private(set) var traceError: String?
    private var stopsAfterLoad = false

    private(set) var heapUsage: (used: Double, total: Double)?
    private(set) var snapshotProgress: (done: Int, total: Int)?
    private var snapshotChunks: [String] = []
    private var snapshotting = false
    var snapshotURL: URL?

    private(set) var coverageRunning = false
    private(set) var coverage: [CoverageEntry] = []
    private(set) var coverageError: String?
    private var styleSheets: [String: (url: String, length: Int)] = [:]

    static let historyLength = 90

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session else { return }
        session.on("Tracing.tracingComplete", self) { [weak self] _, params in self?.traceComplete(params) }
        session.on("Page.loadEventFired", self) { [weak self] _, _ in
            guard let self, stopsAfterLoad, traceState == .recording else { return }
            stopsAfterLoad = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, traceState == .recording else { return }
                stopTrace()
            }
        }
        session.on("HeapProfiler.", self) { [weak self] method, params in
            guard let self, snapshotting else { return }
            if method == "HeapProfiler.addHeapSnapshotChunk", let chunk = params.str("chunk") {
                snapshotChunks.append(chunk)
            } else if method == "HeapProfiler.reportHeapSnapshotProgress" {
                snapshotProgress = (params.int("done") ?? 0, params.int("total") ?? 0)
                changed.send()
            }
        }
        session.on("CSS.styleSheetAdded", self) { [weak self] _, params in
            guard let header = params.obj("header"), let id = header.str("styleSheetId") else { return }
            self?.styleSheets[id] = (header.str("sourceURL") ?? "", header.int("length") ?? 0)
        }
        session.navigated.observe(self) { [weak self] _ in self?.last = nil }
    }

    func stop() {
        guard let session else { return }
        stopPolling()
        if enabled { session.call("Performance.disable") }
        enabled = false
        if traceState == .recording || traceState == .starting { session.call("Tracing.end") }
        if coverageRunning {
            session.call("Profiler.stopPreciseCoverage")
            session.call("Profiler.disable")
            session.call("CSS.stopRuleUsageTracking")
        }
        if snapshotting { session.call("HeapProfiler.disable") }
    }

    func startPolling() {
        guard timer == nil, let session else { return }
        if !enabled {
            enabled = true
            session.call("Performance.enable", ["timeDomain": "timeTicks"])
        }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        session?.call("Performance.getMetrics") { [weak self] result, _ in
            guard let self, let metrics = result?.list("metrics") else { return }
            ingest(metrics)
        }
        session?.call("Runtime.getHeapUsage") { [weak self] result, _ in
            guard let self, let result else { return }
            heapUsage = (result.num("usedSize") ?? 0, result.num("totalSize") ?? 0)
        }
    }

    private func ingest(_ metrics: [JSON]) {
        var now: [String: Double] = [:]
        for metric in metrics {
            if let name = metric.str("name"), let value = metric.num("value") { now[name] = value }
        }
        guard let time = now["Timestamp"] else { return }
        var values: [String: Double] = [
            "heap": now["JSHeapUsedSize"] ?? 0, "heapTotal": now["JSHeapTotalSize"] ?? 0,
            "nodes": now["Nodes"] ?? 0, "listeners": now["JSEventListeners"] ?? 0,
            "documents": now["Documents"] ?? 0, "frames": now["Frames"] ?? 0,
            "cpu": 0, "layouts": 0, "styles": 0,
        ]
        if let last, let then = last["Timestamp"], time > then {
            let elapsed = time - then
            func rate(_ key: String) -> Double { max(((now[key] ?? 0) - (last[key] ?? 0)) / elapsed, 0) }
            values["cpu"] = min(rate("TaskDuration") * 100, 100)
            values["layouts"] = rate("LayoutCount")
            values["styles"] = rate("RecalcStyleCount")
        }
        last = now
        samples.append(PerformanceSample(time: time, values: values))
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
        updated.send()
    }

    private static let categories = [
        "-*", "devtools.timeline", "v8.execute", "disabled-by-default-devtools.timeline",
        "disabled-by-default-devtools.timeline.frame", "toplevel", "blink.console", "blink.user_timing", "latencyInfo",
        "disabled-by-default-devtools.timeline.stack", "disabled-by-default-v8.cpu_profiler", "loading",
        "disabled-by-default-devtools.screenshot",
    ]

    func startTrace(reload: Bool) {
        guard let session, traceState == .idle else { return }
        traceState = .starting
        traceError = nil
        traceSummary = nil
        trace = nil
        traceURL = nil
        changed.send()
        let included = Self.categories.filter { !$0.hasPrefix("-") && $0 != "disabled-by-default-devtools.screenshot" }
        session.call("Tracing.start", [
            "transferMode": "ReturnAsStream", "streamFormat": "json",
            "traceConfig": ["recordMode": "recordAsMuchAsPossible", "includedCategories": included, "excludedCategories": ["*"]],
        ]) { [weak self] _, error in
            guard let self else { return }
            if let error {
                traceState = .idle
                traceError = error
            } else {
                traceState = .recording
                traceStarted = Date()
                if reload {
                    stopsAfterLoad = true
                    session.call("Page.reload", ["ignoreCache": false])
                }
            }
            changed.send()
        }
    }

    func stopTrace() {
        guard let session, traceState == .recording else { return }
        traceState = .stopping
        stopsAfterLoad = false
        changed.send()
        session.call("Tracing.end")
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.traceState == .stopping else { return }
                self.traceState = .idle
                self.traceError = "The trace didn't finish."
                self.changed.send()
            }
        }
    }

    private func traceComplete(_ params: JSON) {
        guard let stream = params.str("stream") else {
            traceState = .idle
            traceError = "The trace came back empty."
            changed.send()
            return
        }
        traceState = .reading(bytes: 0)
        changed.send()
        Task { await read(stream) }
    }

    private func read(_ handle: String) async {
        guard let session else { return }
        var data = Data()
        while true {
            guard let chunk = try? await session.send("IO.read", ["handle": handle, "size": 1 << 20]) else {
                traceError = "Couldn't read the trace."
                break
            }
            let text = chunk.str("data") ?? ""
            if chunk.bool("base64Encoded") {
                data.append(Data(base64Encoded: text) ?? Data())
            } else {
                data.append(Data(text.utf8))
            }
            traceState = .reading(bytes: data.count)
            changed.send()
            if chunk.bool("eof") { break }
        }
        session.call("IO.close", ["handle": handle])
        trace = data.isEmpty ? nil : data
        traceState = .idle
        traceSummarizing = trace != nil
        changed.send()
        guard let trace else { return }
        let summary = await Task.detached(priority: .userInitiated) { TraceSummarizer.summarize(trace) }.value
        traceSummary = summary
        traceSummarizing = false
        changed.send()
    }

    func takeHeapSnapshot(_ done: @escaping @MainActor (Data?) -> Void) {
        guard let session, !snapshotting else { return }
        snapshotting = true
        snapshotChunks = []
        snapshotProgress = (0, 0)
        snapshotURL = nil
        changed.send()
        session.call("HeapProfiler.enable")
        session.call("HeapProfiler.takeHeapSnapshot", ["reportProgress": true, "captureNumericValue": true], timeout: 600) { [weak self] _, error in
            guard let self else { return }
            let data = error == nil ? Data(snapshotChunks.joined().utf8) : nil
            snapshotChunks = []
            snapshotting = false
            snapshotProgress = nil
            session.call("HeapProfiler.disable")
            changed.send()
            done(data)
        }
    }

    var isSnapshotting: Bool { snapshotting }

    func collectGarbage() {
        session?.call("HeapProfiler.collectGarbage") { [weak self] _, _ in self?.poll() }
    }

    func startCoverage() {
        guard let session, !coverageRunning else { return }
        coverageRunning = true
        coverageError = nil
        coverage = []
        changed.send()
        session.call("Profiler.enable")
        session.call("Profiler.startPreciseCoverage", ["callCount": false, "detailed": true]) { [weak self] _, error in
            guard let self, let error else { return }
            coverageError = error
            changed.send()
        }
        session.call("DOM.enable")
        session.call("CSS.enable") { _, _ in session.call("CSS.startRuleUsageTracking") }
    }

    func stopCoverage() {
        guard let session, coverageRunning else { return }
        Task {
            let scripts = (try? await session.send("Profiler.takePreciseCoverage"))?.list("result") ?? []
            session.call("Profiler.stopPreciseCoverage")
            session.call("Profiler.disable")
            let rules = (try? await session.send("CSS.stopRuleUsageTracking"))?.list("ruleUsage") ?? []
            var lengths = styleSheets
            for id in Set(rules.compactMap { $0.str("styleSheetId") }) where lengths[id] == nil {
                let text = (try? await session.send("CSS.getStyleSheetText", ["styleSheetId": id]))?.str("text") ?? ""
                lengths[id] = ("", text.utf8.count)
            }
            coverage = (Self.scriptCoverage(scripts) + Self.styleCoverage(rules, sheets: lengths, page: session.url))
                .sorted { $0.unused > $1.unused }
            coverageRunning = false
            changed.send()
        }
    }

    private static func scriptCoverage(_ scripts: [JSON]) -> [CoverageEntry] {
        var byURL: [String: CoverageEntry] = [:]
        for script in scripts {
            let url = script.str("url") ?? ""
            guard !url.isEmpty, !url.hasPrefix("chrome-extension:") else { continue }
            var ranges: [(start: Int, end: Int, used: Bool)] = []
            for function in script.list("functions") {
                for range in function.list("ranges") {
                    ranges.append((range.int("startOffset") ?? 0, range.int("endOffset") ?? 0, (range.int("count") ?? 0) > 0))
                }
            }
            let length = ranges.map(\.end).max() ?? 0
            guard length > 0 else { continue }
            ranges.sort { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
            var bytes = [Bool](repeating: false, count: length)
            for range in ranges where range.end > range.start {
                for i in max(range.start, 0)..<min(range.end, length) { bytes[i] = range.used }
            }
            let used = bytes.reduce(0) { $0 + ($1 ? 1 : 0) }
            var entry = byURL[url] ?? CoverageEntry(url: url, isCSS: false, total: 0, used: 0)
            entry.total += length
            entry.used += used
            byURL[url] = entry
        }
        return Array(byURL.values)
    }

    private static func styleCoverage(_ rules: [JSON], sheets: [String: (url: String, length: Int)], page: String) -> [CoverageEntry] {
        var byID: [String: (used: Int, end: Int)] = [:]
        for rule in rules {
            guard let id = rule.str("styleSheetId") else { continue }
            let start = rule.int("startOffset") ?? 0, end = rule.int("endOffset") ?? 0
            var entry = byID[id] ?? (0, 0)
            if rule.bool("used") { entry.used += max(end - start, 0) }
            entry.end = max(entry.end, end)
            byID[id] = entry
        }
        var byURL: [String: CoverageEntry] = [:]
        for (id, usage) in byID {
            let sheet = sheets[id]
            let url = sheet.flatMap { $0.url.isEmpty ? nil : $0.url } ?? "\(page) (inline style)"
            var entry = byURL[url] ?? CoverageEntry(url: url, isCSS: true, total: 0, used: 0)
            entry.total += max(sheet?.length ?? 0, usage.end)
            entry.used += usage.used
            byURL[url] = entry
        }
        return Array(byURL.values)
    }
}

enum TraceSummarizer {
    private static let scripting: Set<String> = [
        "FunctionCall", "EvaluateScript", "TimerFire", "EventDispatch", "FireAnimationFrame", "FireIdleCallback",
        "RunMicrotasks", "XHRReadyStateChange", "XHRLoad", "CompileScript", "CompileCode", "CompileModule",
        "EvaluateModule", "MajorGC", "MinorGC", "GCEvent", "BlinkGC.AtomicPhase", "CacheScript", "StreamingCompileScript",
        "WasmCompiledModule", "ScheduleIdleCallback", "TimerInstall", "TimerRemove",
    ]
    private static let rendering: Set<String> = [
        "Layout", "UpdateLayoutTree", "RecalculateStyles", "UpdateLayerTree", "HitTest", "PrePaint", "Layerize",
        "ScheduleStyleRecalculation", "InvalidateLayout", "IntersectionObserverController::computeIntersections",
        "ComputeIntersections", "LayoutShift",
    ]
    private static let painting: Set<String> = [
        "Paint", "CompositeLayers", "PaintImage", "Decode Image", "ImageDecodeTask", "Rasterize", "RasterTask",
        "Commit", "PaintSetup", "UpdateLayer", "Decode LazyPixelRef", "Draw LazyPixelRef", "ResizeImage",
    ]
    private static let loading: Set<String> = [
        "ParseHTML", "ParseAuthorStyleSheet", "ResourceSendRequest", "ResourceReceiveResponse", "ResourceFinish",
        "ResourceReceivedData", "ResourceWillSendRequest", "ResourceChangePriority",
    ]

    static func category(_ name: String) -> String {
        if scripting.contains(name) || name.hasPrefix("v8.") || name.hasPrefix("V8.") { return "Scripting" }
        if rendering.contains(name) { return "Rendering" }
        if painting.contains(name) { return "Painting" }
        if loading.contains(name) { return "Loading" }
        return "Other"
    }

    static func summarize(_ data: Data) -> TraceSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return TraceSummary() }
        let events = (object as? [String: Any])?["traceEvents"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        var summary = TraceSummary()
        summary.events = events.count
        func thread(_ event: [String: Any]) -> String {
            "\((event["pid"] as? NSNumber)?.intValue ?? 0):\((event["tid"] as? NSNumber)?.intValue ?? 0)"
        }
        var mains = Set<String>()
        for event in events where event["ph"] as? String == "M" && event["name"] as? String == "thread_name" {
            if ((event["args"] as? [String: Any])?["name"] as? String) == "CrRendererMain" { mains.insert(thread(event)) }
        }
        var counts: [String: Int] = [:]
        var first = Double.infinity, last = 0.0, frames = 0
        for event in events {
            guard let phase = event["ph"] as? String, phase != "M", let ts = (event["ts"] as? NSNumber)?.doubleValue, ts > 0 else { continue }
            first = min(first, ts)
            last = max(last, ts + ((event["dur"] as? NSNumber)?.doubleValue ?? 0))
            if event["name"] as? String == "DrawFrame" { frames += 1 }
            if phase == "X", mains.contains(thread(event)) { counts[thread(event), default: 0] += 1 }
        }
        guard first < last else { return summary }
        summary.duration = (last - first) / 1000
        if frames > 0 { summary.fps = Double(frames) / max(summary.duration / 1000, 0.001) }
        guard let main = counts.max(by: { $0.value < $1.value })?.key else { return summary }
        struct Slice {
            let start: Double
            let duration: Double
            let name: String
        }
        let tasks = events.compactMap { event -> Slice? in
            guard event["ph"] as? String == "X", thread(event) == main,
                  let ts = (event["ts"] as? NSNumber)?.doubleValue, let dur = (event["dur"] as? NSNumber)?.doubleValue,
                  let name = event["name"] as? String else { return nil }
            return Slice(start: ts, duration: dur, name: name)
        }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.duration > $1.duration }
        var totals: [String: Double] = [:]
        var busy = 0.0
        var stack: [(end: Double, name: String, duration: Double, children: Double)] = []
        func finish() {
            let top = stack.removeLast()
            totals[category(top.name), default: 0] += max(top.duration - top.children, 0)
        }
        for task in tasks {
            while let top = stack.last, top.end <= task.start { finish() }
            if stack.isEmpty {
                busy += task.duration
            } else {
                stack[stack.count - 1].children += task.duration
            }
            stack.append((task.start + task.duration, task.name, task.duration, 0))
            if task.name == "RunTask" || task.name == "ThreadControllerImpl::RunTask", task.duration > 50_000 {
                summary.longTasks.append(.init(start: (task.start - first) / 1000, duration: task.duration / 1000))
            }
        }
        while !stack.isEmpty { finish() }
        summary.longTasks = Array(summary.longTasks.sorted { $0.duration > $1.duration }.prefix(10))
        let idle = max(summary.duration - busy / 1000, 0)
        summary.slices = ["Scripting", "Rendering", "Painting", "Loading", "Other"].map {
            .init(category: $0, milliseconds: (totals[$0] ?? 0) / 1000)
        } + [.init(category: "Idle", milliseconds: idle)]
        return summary
    }

    static func color(_ category: String) -> NSColor {
        switch category {
        case "Scripting": .systemYellow
        case "Rendering": .systemPurple
        case "Painting": .systemGreen
        case "Loading": .systemBlue
        case "Other": .systemGray
        default: Theme.faint(0.12)
        }
    }
}

final class PerformancePanel: InspectorPanelView {
    private let toolbar = InspectorToolbar()
    private let record = InspectorButton("record.circle", tip: "Record a trace")
    private let reloadRecord = InspectorButton("arrow.clockwise.circle", tip: "Reload the page and record a trace")
    private let snapshot = InspectorButton("camera", tip: "Take a heap snapshot")
    private let garbage = InspectorButton("trash", tip: "Collect garbage")
    private let coverageButton = InspectorButton("chart.bar.doc.horizontal", tip: "Record code coverage")
    private let status = Label.make("", size: 11, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let metricsHeading = SectionHeading("Live metrics")
    private var tiles: [MetricTile] = []
    private let traceView = TraceSectionView()
    private let memoryView = MemorySectionView()
    private let coverageView = CoverageSectionView()
    private weak var observedModel: PerformanceModel?
    private var clock: Timer?

    private var model: PerformanceModel? { session.map { $0.model(PerformanceModel.self) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        record.onColor = .systemRed
        record.action = { [weak self] in self?.toggleTrace(reload: false) }
        reloadRecord.action = { [weak self] in self?.toggleTrace(reload: true) }
        snapshot.action = { [weak self] in self?.takeSnapshot() }
        garbage.action = { [weak self] in self?.model?.collectGarbage() }
        coverageButton.onColor = .systemRed
        coverageButton.action = { [weak self] in
            guard let self, let model else { return }
            if model.coverageRunning { model.stopCoverage() } else { model.startCoverage() }
        }
        toolbar.add(record, width: 24)
        toolbar.add(reloadRecord, width: 24)
        toolbar.addSeparator()
        toolbar.add(snapshot, width: 24)
        toolbar.add(garbage, width: 24)
        toolbar.addSeparator()
        toolbar.add(coverageButton, width: 24)
        toolbar.add(status, width: nil)
        addSubview(toolbar)
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        content.addSubview(metricsHeading)
        for spec in MetricTile.Spec.all {
            let tile = MetricTile(spec)
            tiles.append(tile)
            content.addSubview(tile)
        }
        for view in [traceView, memoryView, coverageView] as [NSView] { content.addSubview(view) }
        traceView.save = { [weak self] in self?.saveTrace() }
        traceView.reveal = { [weak self] in
            if let url = self?.model?.traceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        memoryView.reveal = { [weak self] in
            if let url = self?.model?.snapshotURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        coverageView.open = { [weak self] url in self?.session?.revealSource(url: url, line: 0) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        scroll.frame = NSRect(x: 0, y: InspectorToolbar.height, width: bounds.width, height: max(bounds.height - InspectorToolbar.height, 0))
        layoutContent()
    }

    private func layoutContent() {
        let width = max(scroll.contentSize.width, 200)
        let inset: CGFloat = 12, gap: CGFloat = 8
        var y: CGFloat = 10
        metricsHeading.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: 18)
        y += 24
        let columns = max(1, Int((width - 2 * inset + gap) / (170 + gap)))
        let tileWidth = ((width - 2 * inset - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        for (i, tile) in tiles.enumerated() {
            let column = i % columns, row = i / columns
            tile.frame = NSRect(x: inset + CGFloat(column) * (tileWidth + gap), y: y + CGFloat(row) * (MetricTile.height + gap),
                                width: tileWidth, height: MetricTile.height)
        }
        y += CGFloat((tiles.count + columns - 1) / columns) * (MetricTile.height + gap) + 10
        for section in [traceView, memoryView, coverageView] as [SectionView] where !section.isHidden {
            let height = section.height(for: width - 2 * inset)
            section.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: height)
            y += height + 16
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    override func sessionChanged() {
        if let observedModel {
            observedModel.stopPolling()
            observedModel.updated.stopObserving(self)
            observedModel.changed.stopObserving(self)
        }
        observedModel = nil
        if isShown { attach() } else { update() }
    }

    override func panelDidAppear() { attach() }

    override func panelDidDisappear() {
        observedModel?.stopPolling()
        clock?.invalidate()
        clock = nil
    }

    private func attach() {
        guard let model else { return update() }
        if observedModel !== model {
            observedModel = model
            model.updated.observe(self) { [weak self] in self?.metricsUpdated() }
            model.changed.observe(self) { [weak self] in self?.update() }
        }
        model.startPolling()
        update()
        metricsUpdated()
    }

    private func metricsUpdated() {
        let samples = observedModel?.samples ?? []
        for tile in tiles { tile.show(samples) }
        memoryView.heap = observedModel?.heapUsage
    }

    private func update() {
        let model = observedModel
        let state = model?.traceState ?? .idle
        record.isOn = state == .recording || state == .starting
        record.setSymbol(record.isOn ? "stop.circle.fill" : "record.circle")
        record.toolTip = record.isOn ? "Stop recording" : "Record a trace"
        record.isEnabled = model != nil && (state == .idle || state == .recording)
        reloadRecord.isEnabled = model != nil && state == .idle
        snapshot.isEnabled = model != nil && model?.isSnapshotting == false
        garbage.isEnabled = model != nil
        coverageButton.isOn = model?.coverageRunning ?? false
        coverageButton.toolTip = coverageButton.isOn ? "Stop and show coverage" : "Record code coverage"
        coverageButton.isEnabled = model != nil
        status.stringValue = statusText()
        status.textColor = model?.traceError != nil || model?.coverageError != nil ? InspectorTheme.error : .secondaryLabelColor
        if state == .recording, clock == nil {
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.status.stringValue = self?.statusText() ?? "" }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        } else if state != .recording {
            clock?.invalidate()
            clock = nil
        }
        traceView.isHidden = model == nil || (state == .idle && model?.traceSummary == nil && model?.traceSummarizing != true)
        if let model { traceView.show(model) }
        memoryView.isHidden = model == nil
        if let model { memoryView.show(model) }
        coverageView.isHidden = model == nil || (!model!.coverageRunning && model!.coverage.isEmpty)
        if let model { coverageView.show(model) }
        needsLayout = true
    }

    private func statusText() -> String {
        guard let model = observedModel else { return "" }
        if let error = model.traceError { return error }
        if let error = model.coverageError { return error }
        switch model.traceState {
        case .starting: return "Starting…"
        case .recording:
            let elapsed = model.traceStarted.map { Date().timeIntervalSince($0) } ?? 0
            return String(format: "Recording %.1f s", elapsed)
        case .stopping: return "Stopping…"
        case .reading(let bytes): return "Reading trace, \(Format.bytes(Double(bytes)))"
        case .idle: break
        }
        if model.traceSummarizing { return "Summarizing…" }
        if let progress = model.snapshotProgress {
            return progress.total > 0 ? "Snapshot \(Int(Double(progress.done) / Double(progress.total) * 100))%" : "Taking snapshot…"
        }
        if model.coverageRunning { return "Recording coverage: use the page, then stop" }
        return ""
    }

    private func toggleTrace(reload: Bool) {
        guard let model else { return }
        if model.traceState == .recording {
            model.stopTrace()
        } else {
            model.startTrace(reload: reload)
        }
    }

    private var host: String {
        let host = URLComponents(string: session?.url ?? "")?.host ?? "page"
        return host.isEmpty ? "page" : host
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date())
    }

    private func save(_ data: Data, name: String, done: @escaping @MainActor (URL) -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                    done(url)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    private func saveTrace() {
        guard let model, let trace = model.trace else { return }
        save(trace, name: "Trace-\(host)-\(Self.stamp()).json") { [weak self] url in
            model.traceURL = url
            self?.update()
        }
    }

    private func takeSnapshot() {
        guard let model else { return }
        let name = "Heap-\(host)-\(Self.stamp()).heapsnapshot"
        model.takeHeapSnapshot { [weak self] data in
            guard let self, let data else { return }
            save(data, name: name) { [weak self] url in
                model.snapshotURL = url
                self?.update()
            }
        }
    }
}

private final class MetricTile: FlippedView {
    struct Spec {
        let key: String
        let title: String
        let color: NSColor
        let fromZero: Bool
        let fixedMax: Double?
        let format: (Double) -> String
        let detail: ((PerformanceSample) -> String?)?

        static let all: [Self] = [
            Self(key: "cpu", title: "CPU usage", color: .systemBlue, fromZero: true, fixedMax: 100,
                 format: { String(format: "%.0f%%", $0) }, detail: nil),
            Self(key: "heap", title: "JS heap", color: .systemPurple, fromZero: false, fixedMax: nil,
                 format: { Format.bytes($0) }, detail: { "of " + Format.bytes($0.values["heapTotal"] ?? 0) }),
            Self(key: "nodes", title: "DOM nodes", color: .systemGreen, fromZero: false, fixedMax: nil,
                 format: { Int($0).formatted() }, detail: nil),
            Self(key: "listeners", title: "Event listeners", color: .systemOrange, fromZero: false, fixedMax: nil,
                 format: { Int($0).formatted() }, detail: nil),
            Self(key: "documents", title: "Documents", color: .systemTeal, fromZero: false, fixedMax: nil,
                 format: { Int($0).formatted() }, detail: { s in
                     let frames = Int(s.values["frames"] ?? 0)
                     return "\(frames) frame\(frames == 1 ? "" : "s")"
                 }),
            Self(key: "layouts", title: "Layouts", color: .systemPink, fromZero: true, fixedMax: nil,
                 format: { String(format: "%.1f /s", $0) }, detail: nil),
            Self(key: "styles", title: "Style recalcs", color: .systemIndigo, fromZero: true, fixedMax: nil,
                 format: { String(format: "%.1f /s", $0) }, detail: nil),
        ]
    }

    static let height: CGFloat = 84
    private let spec: Spec
    private let title: NSTextField
    private let value = Label.make("–", size: 17, weight: .semibold)
    private let detail = Label.make("", size: 10.5, color: .tertiaryLabelColor)
    private let chart: Sparkline

    init(_ spec: Spec) {
        self.spec = spec
        title = Label.make(spec.title, size: 11, weight: .medium, color: .secondaryLabelColor)
        chart = Sparkline(color: spec.color, fromZero: spec.fromZero, fixedMax: spec.fixedMax, format: spec.format)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        value.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        for view in [title, value, detail, chart] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.faint(0.035).cgColor
            layer?.borderColor = InspectorTheme.separator.cgColor
        }
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 20
        title.frame = NSRect(x: 10, y: 8, width: inner, height: 15)
        value.frame = NSRect(x: 10, y: 24, width: min(value.textWidth + 4, inner), height: 22)
        detail.frame = NSRect(x: value.frame.maxX + 4, y: 30, width: max(inner - value.frame.width - 4, 0), height: 14)
        chart.frame = NSRect(x: 10, y: 50, width: inner, height: bounds.height - 58)
    }

    func show(_ samples: [PerformanceSample]) {
        let series = samples.map { $0.values[spec.key] ?? 0 }
        value.stringValue = series.last.map(spec.format) ?? "–"
        detail.stringValue = samples.last.flatMap { spec.detail?($0) } ?? ""
        chart.values = series
        needsLayout = true
    }
}

private final class Sparkline: NSView {
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    private let color: NSColor
    private let fromZero: Bool
    private let fixedMax: Double?
    private let format: (Double) -> String

    init(color: NSColor, fromZero: Bool, fixedMax: Double?, format: @escaping (Double) -> String) {
        self.color = color
        self.fromZero = fromZero
        self.fixedMax = fixedMax
        self.format = format
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 0, dy: 1)
        InspectorTheme.separator.setFill()
        NSRect(x: plot.minX, y: plot.maxY - 0.5, width: plot.width, height: 0.5).fill()
        guard values.count > 1 else { return }
        var low = fromZero ? 0 : values.min() ?? 0
        var high = fixedMax ?? max(values.max() ?? 1, fromZero ? 1 : 0)
        if !fromZero {
            let pad = max((high - low) * 0.15, max(abs(high) * 0.01, 1))
            low -= pad
            high += pad
        }
        let span = max(high - low, 0.0001)
        let step = plot.width / CGFloat(PerformanceModel.historyLength - 1)
        let offset = plot.width - step * CGFloat(values.count - 1)
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: plot.minX + offset + step * CGFloat(i), y: plot.maxY - plot.height * CGFloat((values[i] - low) / span))
        }
        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<values.count { line.line(to: point(i)) }
        let area = NSBezierPath()
        area.append(line)
        area.line(to: NSPoint(x: point(values.count - 1).x, y: plot.maxY))
        area.line(to: NSPoint(x: point(0).x, y: plot.maxY))
        area.close()
        color.withAlphaComponent(0.12).setFill()
        area.fill()
        color.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
        let label = format(high) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.font(9), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.maxX - size.width, y: -1), withAttributes: attributes)
    }
}

private final class SectionHeading: NSTextField {
    convenience init(_ title: String) {
        self.init(labelWithString: title)
        font = Theme.font(12, .semibold)
        textColor = .labelColor
    }
}

@MainActor
private class SectionView: FlippedView {
    func height(for width: CGFloat) -> CGFloat { 0 }
}

private func smallButton(_ title: String, action: @escaping () -> Void) -> NSButton {
    let button = NSButton.push(title, action: action)
    button.controlSize = .small
    button.font = Theme.font(11)
    return button
}

private final class TraceSectionView: SectionView {
    var save: (() -> Void)?
    var reveal: (() -> Void)?
    private let heading = SectionHeading("Trace")
    private let summary = Label.make("", size: 11.5, color: .secondaryLabelColor)
    private let bar = StackedBar()
    private var legend: [NSTextField] = []
    private var swatches: [NSView] = []
    private let tasksHeading = Label.make("Long tasks", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private var taskLabels: [NSTextField] = []
    private lazy var saveButton = smallButton("Save Trace…") { [weak self] in self?.save?() }
    private lazy var revealButton = smallButton("Show in Finder") { [weak self] in self?.reveal?() }
    private lazy var perfettoButton = smallButton("Open Perfetto") {
        if let url = URL(string: "https://ui.perfetto.dev") { NSWorkspace.shared.open(url) }
    }
    private let hint = Label.wrapping("Open the saved file in Perfetto, or in Chrome's Performance panel, for the full timeline.", size: 11)
    private var hasSummary = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [heading, summary, bar, tasksHeading, saveButton, revealButton, perfettoButton, hint] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ model: PerformanceModel) {
        for view in legend as [NSView] + swatches + taskLabels { view.removeFromSuperview() }
        legend = []
        swatches = []
        taskLabels = []
        guard let trace = model.traceSummary else {
            hasSummary = false
            summary.stringValue = model.traceSummarizing ? "Summarizing the trace…" : "Recording…"
            for view in [bar, tasksHeading, saveButton, revealButton, perfettoButton, hint] as [NSView] { view.isHidden = true }
            needsLayout = true
            return
        }
        hasSummary = true
        var text = "\(Format.duration(trace.duration / 1000)) · \(trace.events.formatted()) events"
        if let fps = trace.fps { text += String(format: " · %.0f fps", fps) }
        if let data = model.trace { text += " · \(Format.bytes(Double(data.count)))" }
        summary.stringValue = text
        let total = max(trace.slices.map(\.milliseconds).reduce(0, +), 0.001)
        bar.slices = trace.slices.map { ($0.milliseconds / total, TraceSummarizer.color($0.category)) }
        for slice in trace.slices where slice.milliseconds > 0 {
            let label = Label.make(String(format: "%@  %@  %.0f%%", slice.category, Format.duration(slice.milliseconds / 1000),
                                          slice.milliseconds / total * 100), size: 11)
            legend.append(label)
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = TraceSummarizer.color(slice.category).cgColor
            swatch.layer?.cornerRadius = 2
            swatches.append(swatch)
        }
        for task in trace.longTasks {
            taskLabels.append(Label.make(String(format: "%@ at %@", Format.duration(task.duration / 1000),
                                                Format.duration(task.start / 1000)), size: 11))
        }
        for view in legend as [NSView] + swatches + taskLabels { addSubview(view) }
        for view in [bar, saveButton, perfettoButton, hint] as [NSView] { view.isHidden = false }
        tasksHeading.isHidden = trace.longTasks.isEmpty
        revealButton.isHidden = model.traceURL == nil
        saveButton.isHidden = model.trace == nil
        needsLayout = true
    }

    override func height(for width: CGFloat) -> CGFloat {
        guard hasSummary else { return 44 }
        let legendRows = CGFloat((legend.count + 1) / 2)
        var height: CGFloat = 22 + 20 + 20 + legendRows * 18 + 8
        if !taskLabels.isEmpty { height += 22 + CGFloat(taskLabels.count) * 17 }
        height += 32 + hint.sizeThatFits(NSSize(width: width, height: 200)).height + 4
        return height
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        heading.frame = NSRect(x: 0, y: 0, width: width, height: 18)
        summary.frame = NSRect(x: 0, y: 22, width: width, height: 16)
        guard hasSummary else { return }
        bar.frame = NSRect(x: 0, y: 44, width: width, height: 10)
        var y: CGFloat = 62
        let column = (width / 2).rounded(.down)
        for (i, label) in legend.enumerated() {
            let x = CGFloat(i % 2) * column
            swatches[i].frame = NSRect(x: x, y: y + 4, width: 9, height: 9)
            label.frame = NSRect(x: x + 14, y: y, width: column - 16, height: 16)
            if i % 2 == 1 || i == legend.count - 1 { y += 18 }
        }
        y += 8
        if !taskLabels.isEmpty {
            tasksHeading.frame = NSRect(x: 0, y: y, width: width, height: 16)
            y += 20
            for label in taskLabels {
                label.frame = NSRect(x: 0, y: y, width: width, height: 16)
                y += 17
            }
            y += 2
        }
        var x: CGFloat = -4
        for button in [saveButton, revealButton, perfettoButton] where !button.isHidden {
            let w = button.fittingSize.width + 8
            button.frame = NSRect(x: x, y: y, width: w, height: 24)
            x += w + 4
        }
        y += 32
        hint.frame = NSRect(x: 0, y: y, width: width, height: hint.sizeThatFits(NSSize(width: width, height: 200)).height)
    }
}

private final class StackedBar: NSView {
    var slices: [(Double, NSColor)] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        var x = bounds.minX
        for (fraction, color) in slices {
            let width = bounds.width * fraction
            color.setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width
        }
    }
}

private final class MemorySectionView: SectionView {
    var reveal: (() -> Void)?
    var heap: (used: Double, total: Double)? {
        didSet { usage.stringValue = heap.map { "JS heap \(Format.bytes($0.used)) used of \(Format.bytes($0.total))" } ?? "" }
    }
    private let heading = SectionHeading("Memory")
    private let usage = Label.make("", size: 11.5, color: .secondaryLabelColor)
    private let snapshot = Label.make("", size: 11.5, color: .secondaryLabelColor)
    private lazy var revealButton = smallButton("Show in Finder") { [weak self] in self?.reveal?() }
    private let hint = Label.wrapping("Heap snapshots open in Chrome DevTools' Memory panel (Load profile).", size: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [heading, usage, snapshot, revealButton, hint] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ model: PerformanceModel) {
        if let progress = model.snapshotProgress {
            snapshot.stringValue = progress.total > 0
                ? "Taking a heap snapshot… \(Int(Double(progress.done) / Double(progress.total) * 100))%" : "Taking a heap snapshot…"
        } else if let url = model.snapshotURL {
            snapshot.stringValue = "Saved \(url.lastPathComponent)"
        } else {
            snapshot.stringValue = "Take a heap snapshot with the camera above."
        }
        revealButton.isHidden = model.snapshotURL == nil || model.snapshotProgress != nil
        needsLayout = true
    }

    override func height(for width: CGFloat) -> CGFloat {
        22 + 20 + 22 + (revealButton.isHidden ? 0 : 30) + hint.sizeThatFits(NSSize(width: width, height: 200)).height
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
        usage.frame = NSRect(x: 0, y: 22, width: bounds.width, height: 16)
        snapshot.frame = NSRect(x: 0, y: 42, width: bounds.width, height: 16)
        var y: CGFloat = 64
        if !revealButton.isHidden {
            revealButton.frame = NSRect(x: -4, y: y, width: revealButton.fittingSize.width + 8, height: 24)
            y += 30
        }
        hint.frame = NSRect(x: 0, y: y, width: bounds.width, height: hint.sizeThatFits(NSSize(width: bounds.width, height: 200)).height)
    }
}

private final class CoverageSectionView: SectionView {
    var open: ((String) -> Void)?
    private let heading = SectionHeading("Coverage")
    private let summary = Label.make("", size: 11.5, color: .secondaryLabelColor)
    private var rows: [CoverageRow] = []
    private static let shown = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(heading)
        addSubview(summary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ model: PerformanceModel) {
        for row in rows { row.removeFromSuperview() }
        rows = []
        if model.coverageRunning {
            summary.stringValue = "Recording… use the page, then press the coverage button again."
        } else {
            let total = model.coverage.map(\.total).reduce(0, +), unused = model.coverage.map(\.unused).reduce(0, +)
            summary.stringValue = total > 0
                ? "\(Format.bytes(Double(unused))) of \(Format.bytes(Double(total))) unused (\(Int(Double(unused) / Double(total) * 100))%)"
                : "Nothing was covered."
            rows = model.coverage.prefix(Self.shown).map { entry in
                let row = CoverageRow(entry)
                row.click = { [weak self] in self?.open?(entry.url) }
                return row
            }
            for row in rows { addSubview(row) }
        }
        needsLayout = true
    }

    override func height(for width: CGFloat) -> CGFloat { 44 + CGFloat(rows.count) * CoverageRow.height }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
        summary.frame = NSRect(x: 0, y: 22, width: bounds.width, height: 16)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: 44 + CGFloat(i) * CoverageRow.height, width: bounds.width, height: CoverageRow.height)
        }
    }
}

private final class CoverageRow: HoverView {
    static let height: CGFloat = 36
    var click: (() -> Void)?
    private let name = Label.make("", size: 11.5)
    private let numbers = Label.make("", size: 10.5, color: .secondaryLabelColor)
    private let bar = StackedBar()
    private let fill = FillLayer()

    init(_ entry: CoverageEntry) {
        super.init(frame: .zero)
        layer?.addSublayer(fill)
        fill.cornerRadius = 5
        let url = URL(string: entry.url)
        let file = url.map { $0.lastPathComponent.isEmpty ? ($0.host ?? entry.url) : $0.lastPathComponent } ?? entry.url
        name.stringValue = (entry.isCSS ? "CSS  " : "JS  ") + file
        name.lineBreakMode = .byTruncatingMiddle
        let percent = entry.total > 0 ? Int(Double(entry.unused) / Double(entry.total) * 100) : 0
        numbers.stringValue = "\(Format.bytes(Double(entry.unused))) unused of \(Format.bytes(Double(entry.total))) · \(percent)%"
        numbers.alignment = .right
        toolTip = entry.url
        let used = entry.total > 0 ? Double(entry.used) / Double(entry.total) : 0
        bar.slices = [(used, NSColor.systemBlue.withAlphaComponent(0.7)), (1 - used, NSColor.systemRed.withAlphaComponent(0.55))]
        for view in [name, numbers, bar] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: -4, dy: 0)
        let numbersWidth = min(numbers.textWidth, bounds.width * 0.55)
        name.frame = NSRect(x: 0, y: 4, width: bounds.width - numbersWidth - 8, height: 16)
        numbers.frame = NSRect(x: bounds.width - numbersWidth, y: 5, width: numbersWidth, height: 15)
        bar.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 5)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.faint(0.05) : nil, in: effectiveAppearance)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { click?() }
    }
}
