import AppKit

struct AgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
private final class Once {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

@MainActor
final class DrawingHolds {
    var releases: [UInt64: () -> Void] = [:]

    func releaseAll() {
        releases.values.forEach { $0() }
        releases = [:]
    }
}

@MainActor
final class AgentCommands {
    @TaskLocal static var drawing: DrawingHolds?
    private let store: BrowserStore
    private var worlds: [WorldKey: Int] = [:]
    private var sessionTabs: [String: UInt64] = [:]
    private var frameNumbers: [UInt64: [Int: FrameRef]] = [:]

    private struct WorldKey: Hashable {
        let tab: UInt64
        let frame: String?
    }

    struct FrameRef {
        let id: String
        let session: String?
    }

    init(store: BrowserStore) {
        self.store = store
    }

    func run(_ argv: [String], session: String = "default") async -> AgentReply {
        guard AgentSettings.enabled else {
            return .failure("Agent access is off. Turn it on in MBGA ▸ Settings ▸ Agents.")
        }
        let command = argv[0].lowercased()
        var args = AgentArguments(argv.dropFirst())
        args.session = session
        let drawing = DrawingHolds()
        defer { drawing.releaseAll() }
        do {
            return try .success(await Self.$drawing.withValue(drawing) { try await perform(command, args) })
        } catch let error as AgentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func perform(_ command: String, _ args: AgentArguments) async throws -> String {
        switch command {
        case "tabs": return tabs(args)
        case "open": return try await open(args)
        case "use": return try use(args)
        case "focus": return try focus(args)
        case "close": return try close(args)
        case "info": return try await info(args)
        case "snapshot", "snap": return try await snapshot(args)
        case "read", "text": return try await read(args)
        case "find": return try await find(args)
        case "click": return try await click(args)
        case "hover": return try await hover(args)
        case "fill", "type": return try await fill(args, append: command == "type" && args.has("append"))
        case "press", "key": return try await press(args)
        case "select": return try await select(args)
        case "scroll": return try await scroll(args)
        case "wait": return try await wait(args)
        case "eval", "js": return try await eval(args)
        case "screenshot", "shot": return try await screenshot(args)
        case "console": return try console(args)
        case "network", "net": return try await network(args)
        case "back", "forward", "reload": return try await navigate(command, args)
        case "goto", "navigate": return try await goto(args)
        case "run": return try await runScript(args)
        case "cdp" where AgentSettings.debug: return try await rawCommand(args)
        case "inspector" where AgentSettings.debug: return try await inspectorCommand(args)
        default: throw AgentError("Unknown command \"\(command)\". Run `mbga help`.")
        }
    }

    private func target(_ args: AgentArguments) throws -> UInt64 {
        if let name = args.flags["tab"] {
            guard let id = UInt64(name.hasPrefix("t") ? String(name.dropFirst()) : name), store.core.tab(id: id) != nil else {
                throw AgentError("No tab \(name). Run `mbga tabs`.")
            }
            return id
        }
        if let id = sessionTabs[args.session], store.core.tab(id: id) != nil { return id }
        guard let id = store.visibleTabID else { throw AgentError("No tab is open. Use `mbga open <url>`.") }
        return id
    }

    private func page(_ id: UInt64) async throws -> MBWebView {
        if let url = store.core.tab(id: id)?.url { try allow(url) }
        let loaded = store.isLoaded(id)
        guard let view = store.engineView(for: id) else { throw AgentError("Tab t\(id) has no page.") }
        if !loaded { try await waitForLoad(id, timeout: 15) }
        view.recordsNetwork = true
        view.attachToFrames()
        store.agentActed(on: id)
        if Self.drawing?.releases[id] == nil {
            let hold = store.holdDrawing(id)
            if let drawing = Self.drawing { drawing.releases[id] = hold.release } else { hold.release() }
            if hold.started { try await Task.sleep(for: .milliseconds(300)) }
        }
        return view
    }

    private func allow(_ url: String) throws {
        if let site = store.agentPreferences.blockedSite(for: url) {
            throw AgentError("The person keeps agents off \(site) (MBGA ▸ Settings ▸ Agents).")
        }
    }

    private func line(_ id: UInt64) -> String {
        guard let tab = store.core.tab(id: id) else { return "t\(id)" }
        let untitled = tab.title.isEmpty || tab.url == tab.title || tab.url.hasSuffix("://" + tab.title)
        var text = untitled ? "t\(id) \(tab.url)" : "t\(id) \(tab.title) — \(tab.url)"
        let report = store.devReport(of: id)
        if let status = report.statusText, (report.status ?? 0) >= 400 || (report.status ?? 0) < 0 { text += " (\(status))" }
        return text
    }

    private func tabs(_ args: AgentArguments) -> String {
        var out: [String] = []
        let agents = store.agentPreferences.ownSpace ? store.agentPreferences.spaceID : nil
        let spaces = args.has("all") ? store.snapshot.spaces
            : store.snapshot.spaces.filter { $0.id == store.activeSpace.id || $0.id == agents }
        let mine = sessionTabs[args.session]
        for space in spaces {
            var title = space.name
            if space.id == agents { title += " (agents' space)" }
            if space.id == store.activeSpace.id { title += " (on screen)" }
            out.append(title + ":")
            let tabs = (space.id == agents ? [] : space.favorites) + space.pinned.compactMap(\.tab) + space.today
            if tabs.isEmpty { out.append("  (no tabs)") }
            for tab in tabs {
                let mark = tab.id == store.visibleTabID ? "*" : tab.id == mine ? ">" : " "
                let blocked = store.agentPreferences.blockedSite(for: tab.url) != nil ? " (kept off)" : ""
                out.append("\(mark) \(line(tab.id))\(blocked)")
            }
        }
        out.append("(* on screen, > yours; act on another with --tab tN)")
        return out.joined(separator: "\n")
    }

    private func open(_ args: AgentArguments) async throws -> String {
        guard let input = args[0] else { throw AgentError("Usage: mbga open <url or search> [--focus]") }
        let url = store.core.resolveInput(text: args.words.joined(separator: " "))
        try allow(url)
        guard let id = store.openTabForAgent(url, focus: args.has("focus")) else { throw AgentError("Couldn't open \(input).") }
        sessionTabs[args.session] = id
        _ = try await page(id)
        try await waitForLoad(id, timeout: Double(args.int("timeout") ?? 15))
        try await waitForQuiet(id, limit: 3)
        return line(id)
    }

    private func use(_ args: AgentArguments) throws -> String {
        guard let name = args[0] else { throw AgentError("Usage: mbga use tN") }
        var named = args
        named.flags["tab"] = name
        let id = try target(named)
        sessionTabs[args.session] = id
        return line(id)
    }

    private func focus(_ args: AgentArguments) throws -> String {
        var named = args
        if let name = args[0] { named.flags["tab"] = name }
        let id = try target(named)
        store.select(id, in: store.spaceID(of: id))
        return line(id)
    }

    private func close(_ args: AgentArguments) throws -> String {
        var named = args
        if let name = args[0] { named.flags["tab"] = name }
        let id = try target(named)
        let closed = line(id)
        store.close(id)
        for (session, tab) in sessionTabs where tab == id { sessionTabs[session] = nil }
        return "closed \(closed)"
    }

    private func info(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        var out = [line(id)]
        let report = store.devReport(of: id)
        if store.navState(of: id).isLoading { out.append("loading") }
        if let status = report.statusText { out.append("status \(status)" + (report.durationText.map { ", \($0)" } ?? "")) }
        if report.errors + report.warnings > 0 { out.append("console: \(report.errors) errors, \(report.warnings) warnings") }
        return out.joined(separator: "\n")
    }

    private func snapshot(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        let options: [String: Any] = [
            "max": args.int("max") ?? 250, "text": args.has("text"), "viewport": args.has("viewport"),
        ]
        let text = try await call(id, view, "snapshot", options) as? String ?? ""
        return text.contains("\u{1}F") ? try await expandFrames(id, view, text, options) : text
    }

    private func read(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        let options: [String: Any] = ["max": args.int("max") ?? 6000, "all": args.has("all")]
        return try await call(id, view, "read", options) as? String ?? ""
    }

    private func find(_ args: AgentArguments) async throws -> String {
        guard !args.words.isEmpty else { throw AgentError("Usage: mbga find <text>") }
        let id = try target(args)
        let view = try await page(id)
        return try await call(id, view, "find", args.words.joined(separator: " ")) as? String ?? ""
    }

    private func eval(_ args: AgentArguments) async throws -> String {
        guard !args.words.isEmpty else { throw AgentError("Usage: mbga eval '<expression>' (runs in the page's own world)") }
        let id = try target(args)
        let view = try await page(id)
        let timeout = Double(args.int("timeout") ?? 60)
        let result: [String: Any]
        do {
            result = try await cdp(view, "Runtime.evaluate", [
                "expression": args.words.joined(separator: " "), "returnByValue": true, "awaitPromise": true,
                "userGesture": true,
            ], timeout: timeout)
        } catch let error as AgentError where error.message.hasPrefix("The page didn't answer") {
            throw AgentError("The code didn't finish within \(Int(timeout)) s (--timeout to allow more).")
        }
        if let exception = result["exceptionDetails"] as? [String: Any] { throw AgentError(Self.describe(exception)) }
        let value = (result["result"] as? [String: Any])?["value"]
        return Self.json(value)
    }

    private func rawCommand(_ args: AgentArguments) async throws -> String {
        guard let method = args[0] else { throw AgentError("Usage: mbga cdp <method> [json]") }
        let view = try await page(try target(args))
        let params = args.words.count > 1
            ? (try? JSONSerialization.jsonObject(with: Data(args.words.dropFirst().joined(separator: " ").utf8))) as? [String: Any]
            : nil
        return Self.json(try await cdp(view, method, params, timeout: args.int("timeout").map(Double.init) ?? 5))
    }

    private func inspectorCommand(_ args: AgentArguments) async throws -> String {
        let action = args[0] ?? ""
        let rest = args.words.dropFirst().joined(separator: " ")
        if let panel = InspectorPanelKind(rawValue: action) {
            store.showInspector(panel)
            return "showing \(panel.rawValue)"
        }
        if action == "at" {
            let view = try await page(try target(args))
            let point = rest.split(separator: " ").compactMap { Double($0) }
            store.webView(view, inspectsElementAt: NSPoint(x: point.first ?? 0, y: point.last ?? 0))
            return "ok"
        }
        guard let session = store.inspectorSession else { throw AgentError("The inspector isn't open on a tab.") }
        switch action {
        case "eval":
            store.showInspector(.console)
            session.model(ConsoleModel.self).evaluate(rest)
        case "select":
            store.showInspector(.elements)
            let model = session.model(ElementsModel.self)
            guard let document = model.document else { throw AgentError("No document yet.") }
            let found = try await session.send("DOM.querySelector", ["nodeId": document.id, "selector": rest])
            let described = try await session.send("DOM.describeNode", ["nodeId": found.int("nodeId") ?? 0])
            model.reveal(backendNodeID: described.obj("node")?.int("backendNodeId") ?? 0)
        case "source":
            let parts = rest.split(separator: " ")
            session.revealSource(url: parts.first.map(String.init) ?? "", line: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        case "row":
            NotificationCenter.default.post(name: InspectorView.debugRow, object: nil, userInfo: ["row": Int(rest) ?? 0])
        case "close":
            store.closeInspector()
        default:
            throw AgentError("Unknown inspector action.")
        }
        return "ok"
    }

    private func console(_ args: AgentArguments) throws -> String {
        let id = try target(args)
        var entries = store.consoleEntries(of: id)
        if args.has("errors") { entries = entries.filter { $0.level >= 3 } }
        if args.has("clear") { store.clearConsole(of: id) }
        let max = args.int("max") ?? 50
        guard !entries.isEmpty else { return "No console messages since the page loaded." }
        let names = ["debug", "info", "warn", "error"]
        var out = entries.suffix(max).map { entry in
            let place = entry.source.isEmpty ? "" : " (\(URL(string: entry.source)?.lastPathComponent ?? entry.source):\(entry.line))"
            return "\(names[min(entry.level, 3)])  \(entry.text.prefix(300))\(place)"
        }
        if entries.count > max { out.insert("… \(entries.count - max) earlier", at: 0) }
        return out.joined(separator: "\n")
    }

    private func network(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        var entries = store.networkEntries(of: id)
        if let number = args.flags["body"].flatMap({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) {
            guard let entry = entries.first(where: { $0.number == number }) else { throw AgentError("No request #\(number).") }
            let body = try await responseBody(view, entry)
            var text = body["body"] as? String ?? ""
            if body["base64Encoded"] as? Bool == true { text = "(\(Data(base64Encoded: text)?.count ?? 0) bytes of binary data)" }
            let max = args.int("max") ?? 6000
            if text.count > max { text = String(text.prefix(max)) + "\n… \(text.count - max) more characters (--max for more)" }
            return "#\(number) \(entry.method) \(entry.status.map(String.init) ?? "—") \(entry.url)\n\n\(text)"
        }
        if args.has("clear") {
            store.clearNetwork(of: id)
            return "Cleared."
        }
        if args.has("failed") { entries = entries.filter { $0.failure != nil || ($0.status ?? 0) >= 400 } }
        if let filter = args.flags["filter"]?.lowercased() { entries = entries.filter { $0.url.lowercased().contains(filter) || $0.type.contains(filter) } }
        if args.has("api") { entries = entries.filter { ["xhr", "fetch"].contains($0.type) } }
        guard !entries.isEmpty else {
            return "No requests recorded. Requests are logged from the first command on a tab; `mbga reload` to see a page's own."
        }
        let origin = URLComponents(string: store.core.tab(id: id)?.url ?? "").map { "\($0.scheme ?? "")://\($0.host ?? "")" + ($0.port.map { ":\($0)" } ?? "") }
        let max = args.int("max") ?? 60
        var out = entries.suffix(max).map { entry -> String in
            var url = entry.url
            if let origin, url.hasPrefix(origin) { url = String(url.dropFirst(origin.count)) }
            if url.count > 90 { url = String(url.prefix(89)) + "…" }
            let status = entry.failure ?? entry.status.map(String.init) ?? "…"
            let size = entry.size.map { $0 >= 1024 ? String(format: "%.1f KB", Double($0) / 1024) : "\($0) B" } ?? ""
            let time = entry.ended.map { "\(Int(($0 - entry.started) * 1000)) ms" } ?? ""
            return "#\(entry.number) \(entry.method) \(status) \(entry.type) \(url) \(size) \(time)".trimmingCharacters(in: .whitespaces)
        }
        if entries.count > max { out.insert("… \(entries.count - max) earlier (--max for more)", at: 0) }
        return out.joined(separator: "\n")
    }

    private func click(_ args: AgentArguments) async throws -> String {
        let target = try await element(args, usage: "mbga click <ref> [--force]")
        let (id, view) = (target.id, target.view)
        let spot = try await point(target)
        let label = spot.label
        if !spot.covered.isEmpty, !args.has("force") {
            throw AgentError("\(label) is covered by \(spot.covered). Close that first, or use --force to click whatever is on top.")
        }
        if spot.disabled, !args.has("force") {
            throw AgentError("\(label) is disabled, so the page ignores clicks on it. Fill in what it asks for first, or use --force to click anyway.")
        }
        let before = store.core.tab(id: id)?.url
        let requests = store.networkEntries(of: id).last?.number
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            _ = try await cdp(view, "Input.dispatchMouseEvent", [
                "type": type, "x": spot.x, "y": spot.y, "button": type == "mouseMoved" ? "none" : "left",
                "buttons": type == "mousePressed" ? 1 : 0, "clickCount": type == "mouseMoved" ? 0 : 1,
            ])
        }
        let moved = try await settle(id, from: before, requests: requests)
        guard moved.isEmpty else { return "clicked \(label)" + moved }
        let now = try? await call(id, view, "state", target.ref, in: target.frame) as? [String: Any]
        guard let now, let after = now["label"] as? String else { return "clicked \(label)" }
        let prefix = target.frameNumber.map { "f\($0):" } ?? ""
        if let checked = spot.checked, now["checked"] as? Bool == checked {
            return "clicked \(prefix + after)\nIt's still \(checked ? "checked" : "unchecked"): the page didn't take the click there. Try its label (click text=<its words>)."
        }
        return "clicked \(prefix + after)"
    }

    private func hover(_ args: AgentArguments) async throws -> String {
        let target = try await element(args, usage: "mbga hover <ref>")
        let spot = try await point(target)
        _ = try await cdp(target.view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": spot.x, "y": spot.y])
        return "hovering \(spot.label)"
    }

    private func fill(_ args: AgentArguments, append: Bool) async throws -> String {
        guard args.words.count >= 2 else { throw AgentError("Usage: mbga fill <ref> <text> [--enter]  (type --append adds to what's there)") }
        let target = try await element(args, usage: "")
        let (id, view, ref, frame) = (target.id, target.view, target.ref, target.frame)
        let text = args.words.dropFirst().joined(separator: " ")
        let prefix = target.frameNumber.map { "f\($0):" } ?? ""
        let label = prefix + (try await call(id, view, "focus", ["ref": ref, "select": !append], in: frame) as? String ?? ref)
        if text.isEmpty {
            try await key(view, "Backspace", session: frame?.session)
        } else {
            _ = try await cdp(view, "Input.insertText", ["text": text], session: frame?.session)
        }
        let before = store.core.tab(id: id)?.url
        if args.has("enter") {
            let requests = store.networkEntries(of: id).last?.number
            try await key(view, "Enter", session: frame?.session)
            return "filled \(label) and pressed Enter" + (try await settle(id, from: before, requests: requests))
        }
        return "filled " + ((try? await call(id, view, "label", ref, in: frame) as? String).map { prefix + $0 } ?? label)
    }

    private func press(_ args: AgentArguments) async throws -> String {
        guard let name = args[0] else { throw AgentError("Usage: mbga press <key>  (Enter, Tab, Escape, ArrowDown, Shift+Tab, …)") }
        let id = try target(args)
        let view = try await page(id)
        let before = store.core.tab(id: id)?.url
        let requests = store.networkEntries(of: id).last?.number
        for _ in 0..<(args.int("times") ?? 1) { try await key(view, name) }
        return "pressed \(name)" + (try await settle(id, from: before, requests: requests))
    }

    private func select(_ args: AgentArguments) async throws -> String {
        guard args.words.count >= 2 else { throw AgentError("Usage: mbga select <ref> <option text or value>") }
        let target = try await element(args, usage: "")
        let value = args.words.dropFirst().joined(separator: " ")
        return try await call(target.id, target.view, "choose", ["ref": target.ref, "value": value], in: target.frame) as? String ?? ""
    }

    private func navigate(_ command: String, _ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        switch command {
        case "back": view.goBack()
        case "forward": view.goForward()
        default:
            if args.has("hard") { view.reloadIgnoringCache() } else { view.reload() }
        }
        try await Task.sleep(for: .milliseconds(150))
        try await waitForLoad(id, timeout: 15)
        try await waitForQuiet(id, limit: 3)
        return line(id)
    }

    private func goto(_ args: AgentArguments) async throws -> String {
        guard !args.words.isEmpty else { throw AgentError("Usage: mbga goto <url>") }
        let id = try target(args)
        let view = try await page(id)
        let url = store.core.resolveInput(text: args.words.joined(separator: " "))
        try allow(url)
        store.core.updateTab(id: id, url: url, title: nil)
        view.loadURL(url)
        try await Task.sleep(for: .milliseconds(150))
        try await waitForLoad(id, timeout: Double(args.int("timeout") ?? 15))
        try await waitForQuiet(id, limit: 3)
        return line(id)
    }

    private func wait(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let timeout = Double(args.int("timeout") ?? 15)
        guard let what = args[0] else { throw AgentError("Usage: mbga wait load | idle | <ms> | text <text> | gone <text>") }
        if let ms = Int(what) {
            try await Task.sleep(for: .milliseconds(ms))
            return "waited \(ms) ms"
        }
        if what == "load" {
            try await waitForLoad(id, timeout: timeout)
            return line(id)
        }
        if what == "idle" {
            _ = try await page(id)
            try await waitForLoad(id, timeout: timeout)
            guard try await waitForQuiet(id, limit: timeout) else {
                throw AgentError("t\(id) was still making requests after \(Int(timeout)) s (`mbga network` shows them).")
            }
            return "idle: " + line(id)
        }
        let text = args.words.dropFirst().joined(separator: " ")
        guard what == "text" || what == "gone", !text.isEmpty else {
            throw AgentError("Usage: mbga wait load | idle | <ms> | text <text> | gone <text>")
        }
        let view = try await page(id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = try await call(id, view, "contains", text) as? Bool ?? false
            if found == (what == "text") { return what == "text" ? "found \"\(text)\"" : "\"\(text)\" is gone" }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw AgentError("Timed out after \(Int(timeout)) s waiting for \"\(text)\" to \(what == "text" ? "appear" : "go").")
    }

    private func screenshot(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        let size = try await call(id, view, "viewport", nil) as? [String: Any] ?? [:]
        let width = size["width"] as? Double ?? 800, height = size["height"] as? Double ?? 600
        let full = args.has("full")
        var params: [String: Any] = ["format": "png"]
        let scale = 1 / max(size["dpr"] as? Double ?? 1, 1)
        if full {
            let page = size["page"] as? Double ?? height
            params["captureBeyondViewport"] = true
            params["clip"] = ["x": 0, "y": 0, "width": width, "height": min(page, 16384), "scale": scale]
        } else {
            let scrollY = size["scrollY"] as? Double ?? 0, scrollX = size["scrollX"] as? Double ?? 0
            params["clip"] = ["x": scrollX, "y": scrollY, "width": width, "height": height, "scale": scale]
        }
        let result = try await cdp(view, "Page.captureScreenshot", params, timeout: 10)
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw AgentError("The screenshot failed.")
        }
        let path = args.flags["out"].map { ($0 as NSString).expandingTildeInPath }
            ?? NSTemporaryDirectory() + "mbga-t\(id)-\(Int(Date().timeIntervalSince1970)).png"
        try data.write(to: URL(fileURLWithPath: path))
        return "\(path) (\(Int(width)) × \(Int(full ? (size["page"] as? Double ?? height) : height)))"
    }

    private func runScript(_ args: AgentArguments) async throws -> String {
        guard let source = args.words.first, !source.isEmpty else {
            throw AgentError("Usage: mbga run <file.js | - | -e 'code'>")
        }
        if args.has("tab") { sessionTabs[args.session] = try target(args) }
        let script = AgentScriptRunner(commands: self, session: args.session, timeout: Double(args.int("timeout") ?? 120))
        return try await script.run(source)
    }

    private func element(_ args: AgentArguments, usage: String) async throws -> Target {
        guard var ref = args[0] else { throw AgentError("Usage: \(usage)") }
        let id = try target(args)
        let view = try await page(id)
        if ref.hasPrefix("["), ref.hasSuffix("]") { ref = String(ref.dropFirst().dropLast()) }
        if ref.hasPrefix("f"), let colon = ref.firstIndex(of: ":"), let number = Int(ref[ref.index(after: ref.startIndex)..<colon]) {
            guard let frame = frameNumbers[id]?[number] else {
                throw AgentError("No frame f\(number) now. Run `mbga snapshot` for fresh refs.")
            }
            return Target(id: id, view: view, ref: String(ref[ref.index(after: colon)...]), frame: frame, frameNumber: number)
        }
        return Target(id: id, view: view, ref: ref, frame: nil, frameNumber: nil)
    }

    struct Target {
        let id: UInt64
        let view: MBWebView
        let ref: String
        let frame: FrameRef?
        let frameNumber: Int?
    }

    private func key(_ view: MBWebView, _ name: String, session: String? = nil) async throws {
        var parts = name.split(separator: "+").map(String.init)
        let keyName = parts.removeLast()
        var modifiers = 0
        for part in parts {
            switch part.lowercased() {
            case "alt", "option": modifiers |= 1
            case "ctrl", "control": modifiers |= 2
            case "meta", "cmd", "command": modifiers |= 4
            case "shift": modifiers |= 8
            default: throw AgentError("Unknown modifier \(part)")
            }
        }
        let named: [String: (code: String, keyCode: Int, text: String)] = [
            "Enter": ("Enter", 13, "\r"), "Tab": ("Tab", 9, ""), "Escape": ("Escape", 27, ""),
            "Backspace": ("Backspace", 8, ""), "Delete": ("Delete", 46, ""), "Space": ("Space", 32, " "),
            "ArrowUp": ("ArrowUp", 38, ""), "ArrowDown": ("ArrowDown", 40, ""), "ArrowLeft": ("ArrowLeft", 37, ""),
            "ArrowRight": ("ArrowRight", 39, ""), "Home": ("Home", 36, ""), "End": ("End", 35, ""),
            "PageUp": ("PageUp", 33, ""), "PageDown": ("PageDown", 34, ""),
        ]
        let aliases = ["esc": "Escape", "return": "Enter", "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft",
                       "right": "ArrowRight", "space": "Space", "del": "Delete", "backspace": "Backspace",
                       "tab": "Tab", "enter": "Enter", "escape": "Escape", "pageup": "PageUp", "pagedown": "PageDown",
                       "home": "Home", "end": "End"]
        let canonical = aliases[keyName.lowercased()] ?? keyName
        var event: [String: Any] = ["modifiers": modifiers]
        if let known = named[canonical] {
            event["key"] = canonical == "Space" ? " " : canonical
            event["code"] = known.code
            event["windowsVirtualKeyCode"] = known.keyCode
            if !known.text.isEmpty, modifiers & 7 == 0 { event["text"] = known.text }
        } else if canonical.count == 1 {
            let character = modifiers & 8 != 0 ? canonical.uppercased() : canonical.lowercased()
            event["key"] = character
            event["code"] = canonical.first!.isLetter ? "Key\(canonical.uppercased())" : "Digit\(canonical)"
            event["windowsVirtualKeyCode"] = Int(canonical.uppercased().unicodeScalars.first!.value)
            if modifiers & 7 == 0 { event["text"] = character }
        } else {
            throw AgentError("Unknown key \(keyName)")
        }
        var down = event
        down["type"] = event["text"] != nil ? "keyDown" : "rawKeyDown"
        _ = try await cdp(view, "Input.dispatchKeyEvent", down, session: session)
        var up = event
        up["type"] = "keyUp"
        up["text"] = nil
        _ = try await cdp(view, "Input.dispatchKeyEvent", up, session: session)
    }

    private func cdp(_ view: MBWebView, _ method: String, _ params: [String: Any]? = nil,
                     session: String? = nil, timeout: Double = 20) async throws -> [String: Any] {
        let json = try params.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let once = Once()
        let text: String = try await withCheckedThrowingContinuation { continuation in
            view.sendDevToolsCommand(method, params: json, session: session) { result, error in
                guard once.claim() else { return }
                if let result { continuation.resume(returning: result) } else {
                    continuation.resume(throwing: AgentError(error ?? "\(method) failed"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(throwing: AgentError("The page didn't answer \(method) within \(Int(timeout)) s."))
            }
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func call(_ id: UInt64, _ view: MBWebView, _ function: String, _ argument: Any?,
                      in frame: FrameRef? = nil) async throws -> Any? {
        let argumentJSON = argument.map { Self.json($0) } ?? "null"
        let expression = "__mbga.\(function)(\(argumentJSON))"
        for attempt in 0..<2 {
            let context = try await world(id, view, frame: frame, fresh: attempt > 0)
            let result: [String: Any]
            do {
                result = try await cdp(view, "Runtime.evaluate", [
                    "expression": expression, "contextId": context, "returnByValue": true, "awaitPromise": true,
                ], session: frame?.session)
            } catch let error as AgentError where attempt == 0 && error.message.contains("context") {
                continue
            }
            if let exception = result["exceptionDetails"] as? [String: Any] {
                let message = Self.describe(exception)
                if attempt == 0, message.contains("__mbga is not defined") { continue }
                throw AgentError(message.replacingOccurrences(of: "Error: ", with: ""))
            }
            return (result["result"] as? [String: Any])?["value"]
        }
        throw AgentError("The page changed while reading it; try again.")
    }

    private func world(_ id: UInt64, _ view: MBWebView, frame: FrameRef?, fresh: Bool) async throws -> Int {
        let key = WorldKey(tab: id, frame: frame?.id)
        if !fresh, let context = worlds[key] { return context }
        var frameID = frame?.id
        if frameID == nil {
            let tree = try await cdp(view, "Page.getFrameTree")
            frameID = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
        }
        guard let frameID else { throw AgentError("The page has no frame yet.") }
        let made = try await cdp(view, "Page.createIsolatedWorld", ["frameId": frameID, "worldName": "mbga-agent"],
                                 session: frame?.session)
        guard let context = made["executionContextId"] as? Int else { throw AgentError("Couldn't reach the page.") }
        _ = try await cdp(view, "Runtime.evaluate", ["expression": AgentScript.source, "contextId": context],
                          session: frame?.session)
        worlds[key] = context
        return context
    }

    private func expandFrames(_ id: UInt64, _ view: MBWebView, _ text: String, _ options: [String: Any]) async throws -> String {
        let tree = try await cdp(view, "Page.getFrameTree")
        let children = ((tree["frameTree"] as? [String: Any])?["childFrames"] as? [[String: Any]] ?? [])
            .compactMap { ($0["frame"] as? [String: Any])?["id"] as? String }
        let main = try await world(id, view, frame: nil, fresh: false)
        var numbers: [Int: FrameRef] = [:]
        for frameID in children {
            guard let owner = try? await cdp(view, "DOM.getFrameOwner", ["frameId": frameID]),
                  let node = owner["backendNodeId"] as? Int,
                  let resolved = try? await cdp(view, "DOM.resolveNode", ["backendNodeId": node, "executionContextId": main]),
                  let object = (resolved["object"] as? [String: Any])?["objectId"] as? String,
                  let found = try? await cdp(view, "Runtime.callFunctionOn", [
                      "objectId": object, "functionDeclaration": "function(){return __mbga.frameNumber(this)}", "returnByValue": true,
                  ]),
                  let number = (found["result"] as? [String: Any])?["value"] as? Int, number > 0
            else { continue }
            numbers[number] = FrameRef(id: frameID, session: view.frameSessions[frameID])
        }
        frameNumbers[id] = numbers
        var framed = options
        framed["framed"] = true
        framed["max"] = min(options["max"] as? Int ?? 250, 120)
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let start = line.range(of: "\u{1}F"), let end = line.range(of: "\u{1}", range: start.upperBound..<line.endIndex),
                  let number = Int(line[start.upperBound..<end.lowerBound]) else {
                out.append(line)
                continue
            }
            let indent = String(line[..<start.lowerBound])
            let label = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let frame = numbers[number] else {
                out.append("\(indent)[frame] \(label) (not read yet; snapshot again)")
                continue
            }
            let inner = (try? await call(id, view, "snapshot", framed, in: frame) as? String)
            guard let inner else {
                out.append("\(indent)[frame] \(label) (couldn't be read)")
                continue
            }
            out.append("\(indent)frame \(label):")
            for innerLine in inner.components(separatedBy: "\n") where !innerLine.isEmpty {
                var line = innerLine.replacingOccurrences(of: "[e", with: "[f\(number):e")
                if let mark = line.range(of: "\u{1}F") {
                    let after = line[mark.upperBound...].split(separator: "\u{1}", maxSplits: 1)
                    line = String(line[..<mark.lowerBound]) + "[frame]" + (after.count > 1 ? after[1] : "") + " (not read)"
                }
                out.append("\(indent)  \(line)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func describe(_ exception: [String: Any]) -> String {
        ((exception["exception"] as? [String: Any])?["description"] as? String)?
            .components(separatedBy: "\n").first ?? exception["text"] as? String ?? "The script failed."
    }

    static func json(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let string = value as? String {
            let data = try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])
            return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"\""
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension AgentCommands {
    private func scroll(_ args: AgentArguments) async throws -> String {
        let id = try target(args)
        let view = try await page(id)
        let word = args[0] ?? "down"
        if (word.hasPrefix("e") && Int(word.dropFirst()) != nil) || word.hasPrefix("f") || word.contains("=") {
            let target = try await element(args, usage: "")
            if let number = target.frameNumber { _ = try await call(id, view, "frameBox", number) }
            return try await call(id, view, "reveal", target.ref, in: target.frame) as? String ?? ""
        }
        let size = try await call(id, view, "viewport", nil) as? [String: Any] ?? [:]
        let height = size["height"] as? Double ?? 600
        let amount = args[1].flatMap(Double.init) ?? height * 0.8
        let (dx, dy): (Double, Double) = switch word {
        case "up": (0, -amount)
        case "left": (-amount, 0)
        case "right": (amount, 0)
        case "top": (0, -1e7)
        case "bottom": (0, 1e7)
        default: (0, amount)
        }
        let requests = store.networkEntries(of: id).last?.number
        let position = try await call(id, view, "scrollPage", ["dx": dx, "dy": dy]) as? String ?? "scrolled"
        try await Task.sleep(for: .milliseconds(250))
        if store.networkEntries(of: id).last?.number != requests { try await waitForQuiet(id, limit: 2) }
        return position
    }

    private func responseBody(_ view: MBWebView, _ entry: NetworkEntry) async throws -> [String: Any] {
        do {
            return try await cdp(view, "Network.getResponseBody", ["requestId": entry.requestID])
        } catch let error as AgentError where error.message.contains("No resource") || error.message.contains("No data") {
            throw AgentError("The browser no longer has the body of #\(entry.number): it keeps them for the page as it is now, "
                + "while there's room. Ask soon after the request, or `mbga reload` and ask again.")
        }
    }

    private func point(_ target: Target) async throws -> Spot {
        var origin = (x: 0.0, y: 0.0)
        if let number = target.frameNumber {
            let box = try await call(target.id, target.view, "frameBox", number) as? [String: Any] ?? [:]
            origin = (box["x"] as? Double ?? 0, box["y"] as? Double ?? 0)
        }
        let point = try await call(target.id, target.view, "point", target.ref, in: target.frame) as? [String: Any] ?? [:]
        return Spot(x: origin.x + (point["x"] as? Double ?? 0), y: origin.y + (point["y"] as? Double ?? 0),
                    label: (target.frameNumber.map { "f\($0):" } ?? "") + (point["label"] as? String ?? target.ref),
                    covered: point["covered"] as? String ?? "", disabled: point["disabled"] as? Bool ?? false,
                    checked: point["checked"] as? Bool)
    }

    struct Spot {
        let x: Double
        let y: Double
        let label: String
        let covered: String
        let disabled: Bool
        let checked: Bool?
    }

    private func settle(_ id: UInt64, from before: String?, requests: Int?) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        if store.navState(of: id).isLoading { try await waitForLoad(id, timeout: 15) }
        if store.networkEntries(of: id).last?.number != requests { try await waitForQuiet(id, limit: 3) }
        guard let after = store.core.tab(id: id)?.url, after != before else { return "" }
        return "\n→ " + line(id)
    }

    private func waitForLoad(_ id: UInt64, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.navState(of: id).isLoading || !store.isLoaded(id) {
            guard Date() < deadline else { throw AgentError("t\(id) is still loading after \(Int(timeout)) s.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static let awaitedRequests: Set<String> = ["script", "xhr", "fetch"]

    @discardableResult
    private func waitForQuiet(_ id: UInt64, limit: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        var last = store.networkEntries(of: id).last?.number
        var quietSince = Date()
        while Date() < deadline {
            let entries = store.networkEntries(of: id)
            let busy = entries.contains { $0.ended == nil && $0.failure == nil && Self.awaitedRequests.contains($0.type) }
            if busy || entries.last?.number != last {
                last = entries.last?.number
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.5 {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

enum AgentScript {
    static let source = #"""
    (() => {
    if (window.__mbga) return;
    const S = { next: 1, byRef: new Map(), refOf: new WeakMap(), frames: [] };
    const ACT = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[role=spinbutton],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"])';
    const HEAD = 'h1,h2,h3,h4,h5,h6,[role=heading]';
    const TEXT = 'p,li,td,th,dt,dd,blockquote,pre,figcaption,caption';
    const LAND = { NAV: 'nav', MAIN: 'main', HEADER: 'header', FOOTER: 'footer', ASIDE: 'aside', FORM: 'form', DIALOG: 'dialog' };
    const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK']);
    const clean = (s, n) => { s = (s || '').replace(/\s+/g, ' ').trim(); return n && s.length > n ? s.slice(0, n - 1) + '…' : s; };
    const ref = el => { let r = S.refOf.get(el); if (!r) { r = 'e' + S.next++; S.refOf.set(el, r); } S.byRef.set(r, el); return r; };
    const shown = el => el.checkVisibility
      ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
        || (getComputedStyle(el).display === 'contents' && !!el.parentElement && shown(el.parentElement))
      : el.getClientRects().length > 0;
    // A ref from a snapshot, or css=<selector> / text=<words> for code
    // that already knows the page.
    const get = r => {
      if (r.startsWith('css=')) { const el = document.querySelector(r.slice(4)); if (!el) throw new Error(`Nothing matches ${r.slice(4)}.`); return el; }
      if (r.startsWith('text=')) {
        const q = r.slice(5).toLowerCase();
        let fallback = null;
        for (const el of document.body.querySelectorAll('*')) {
          if (SKIP.has(el.tagName) || !shown(el)) continue;
          const own = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join(' ');
          if (!(own + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.value || '')).toLowerCase().includes(q)) continue;
          // Something to act on wins over a heading or paragraph saying the same.
          const label = el.closest('label');
          const target = (label && label.control) || el.closest(ACT);
          if (target) return target;
          fallback = fallback || el;
        }
        if (fallback) return fallback;
        throw new Error(`Nothing on the page says "${r.slice(5)}".`);
      }
      const el = S.byRef.get(r);
      if (!el || !el.isConnected) throw new Error(`No element ${r} on the page now. Run \`mbga snapshot\` for fresh refs.`);
      return el;
    };
    function role(el) {
      const r = el.getAttribute('role'); if (r) return r.split(' ')[0];
      const t = el.tagName;
      if (t === 'A') return 'link';
      if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
      if (t === 'SELECT') return 'combobox';
      if (t === 'TEXTAREA') return 'textbox';
      if (t === 'INPUT') { const ty = (el.type || 'text').toLowerCase(); return { checkbox: 'checkbox', radio: 'radio', range: 'slider', submit: 'button', button: 'button', reset: 'button', image: 'button', file: 'file', color: 'color', search: 'searchbox', number: 'spinbutton' }[ty] || 'textbox'; }
      if (/^H[1-6]$/.test(t)) return 'heading';
      if (el.isContentEditable) return 'textbox';
      return 'clickable';
    }
    const typing = el => ['textbox', 'searchbox', 'spinbutton', 'combobox'].includes(role(el)) && el.tagName !== 'SELECT';
    function name(el) {
      let n = el.getAttribute('aria-label'); if (n && n.trim()) return n;
      const by = el.getAttribute('aria-labelledby');
      if (by) { n = by.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' '); if (n.trim()) return n; }
      // A label's own words, not those of the control inside it.
      if (el.labels && el.labels.length) { n = Array.from(el.labels).map(labelText).join(' '); if (n.trim()) return n; }
      if (el.tagName === 'IMG') return el.alt || '';
      if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type)) return el.value;
      if (!typing(el)) { n = el.innerText; if (n && n.trim()) return n; }
      return el.getAttribute('placeholder') || el.getAttribute('title') || el.querySelector?.('img[alt]')?.alt || el.querySelector?.('[aria-label]')?.getAttribute('aria-label') || el.getAttribute('name') || '';
    }
    function labelText(l) {
      const copy = l.cloneNode(true);
      copy.querySelectorAll('input,select,textarea,button').forEach(c => c.remove());
      return copy.textContent;
    }
    function describe(el) {
      const ro = role(el);
      let s = `[${ref(el)}] ${ro}`;
      const nm = clean(name(el), 80);
      if (nm) s += ` "${nm.replace(/"/g, "'")}"`;
      if (ro === 'link') {
        const h = el.getAttribute('href');
        if (h && !h.startsWith('javascript:') && h !== '#') { try { const u = new URL(h, location.href); s += ' → ' + (u.origin === location.origin ? u.pathname + u.search + u.hash : clean(u.href, 70)); } catch (e) {} }
      }
      if (typing(el)) {
        const v = el.isContentEditable ? el.innerText : el.value;
        if (v) s += ` = "${clean(el.type === 'password' ? '•'.repeat(Math.min(v.length, 8)) : v, 60)}"`;
        if (el.tagName === 'INPUT' && !['text', 'search', 'number', 'password'].includes(el.type)) s += ` (${el.type})`;
      }
      if (el.tagName === 'SELECT') s += ` = "${clean(el.selectedOptions[0]?.text, 40)}" of ${el.options.length}`;
      if (['checkbox', 'radio', 'switch', 'menuitemcheckbox'].includes(ro)) s += (el.checked || el.getAttribute('aria-checked') === 'true') ? ' [x]' : ' [ ]';
      if (ro === 'tab' && el.getAttribute('aria-selected') === 'true') s += ' (selected)';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' (disabled)';
      const ex = el.getAttribute('aria-expanded'); if (ex) s += ex === 'true' ? ' (expanded)' : ' (collapsed)';
      if (document.activeElement === el) s += ' (focused)';
      return s;
    }
    // Divs that act as buttons: a pointer cursor its parent doesn't have.
    function pointer(el) {
      if (!el.firstChild || el.children.length > 8) return false;
      const c = getComputedStyle(el).cursor;
      return c === 'pointer' && (!el.parentElement || getComputedStyle(el.parentElement).cursor !== 'pointer');
    }
    function where() {
      const max = Math.max(document.documentElement.scrollHeight - innerHeight, 0);
      return max > 0 ? `scrolled ${Math.round(scrollY)} of ${max} px` : 'fits on screen';
    }
    function snapshot(o) {
      o = o || {};
      S.frames = [];
      const max = o.max || 250, lines = [], vh = innerHeight;
      let more = 0, above = false, visible = false, below = false;
      const emit = (el, text, depth) => {
        const r = el.getBoundingClientRect();
        if (o.viewport && (r.bottom < 0 || r.top > vh)) return;
        if (r.bottom < 0) above = true;
        else if (r.top > vh) { if (!below && lines.length) lines.push('--- below the visible area ---'); below = true; }
        else if (!visible) { if (above) lines.push('--- visible area ---'); visible = true; }
        if (lines.length >= max) { more++; return; }
        lines.push('  '.repeat(depth) + text);
      };
      const visit = (root, depth) => {
        for (let el = root.firstElementChild; el; el = el.nextElementSibling) {
          if (SKIP.has(el.tagName)) continue;
          if (!shown(el)) continue;
          if (el.matches(HEAD)) { const lv = +(el.getAttribute('aria-level') || el.tagName[1] || 2); emit(el, '#'.repeat(Math.min(lv, 6) || 2) + ' ' + clean(el.innerText, 100), depth); continue; }
          const act = el.matches(ACT) || (el.tagName !== 'BODY' && pointer(el));
          if (act && !(role(el) === 'clickable' && el.querySelector(ACT))) { emit(el, describe(el), depth); continue; }
          if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
            let label = clean(el.title || el.name || '', 50);
            try { const u = new URL(el.src, location.href); label = (label ? label + ' ' : '') + `(${u.host || u.protocol})`; } catch (e) {}
            let doc = null;
            try { doc = el.contentDocument; } catch (e) {}
            // The same site's frames are read here; others, in their own
            // process, are filled in by MBGA from a marker.
            if (doc && doc.body) { emit(el, `frame ${label}:`, depth); visit(doc.body, depth + 1); }
            else { S.frames.push(el); emit(el, `\u0001F${S.frames.length}\u0001 ${label}`, depth); }
            continue;
          }
          if (el.tagName === 'IMG' && el.alt && o.text) { emit(el, `img "${clean(el.alt, 60)}"`, depth); continue; }
          if (o.text && el.tagName === 'TR') {
            const cells = Array.from(el.cells).map(c => clean(c.innerText, 60)).filter(Boolean);
            if (cells.length) emit(el, cells.join(' | '), depth);
            if (!el.querySelector(ACT)) continue;
          }
          else if (el.tagName === 'LABEL' && el.control) { /* named by its control */ }
          else if (o.text && el.matches(TEXT)) { const t = clean(el.innerText, 200); if (t) emit(el, t, depth); if (!el.querySelector(ACT)) continue; }
          // Apps put text straight in divs and spans: their own text counts.
          else if (o.text) { const own = clean(Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join(' '), 200); if (own.length > 1) emit(el, own, depth); }
          const land = LAND[el.tagName] || ({ navigation: 'nav', main: 'main', dialog: 'dialog', alertdialog: 'dialog', banner: 'header', contentinfo: 'footer', search: 'search', form: 'form' })[el.getAttribute('role')];
          let d = depth;
          if (land) { const label = clean(el.getAttribute('aria-label'), 40); emit(el, land + (label ? ` "${label}"` : '') + ':', depth); d++; }
          visit(el, d);
          if (el.shadowRoot) visit(el.shadowRoot, d);
        }
      };
      if (document.body) visit(document.body, 0);
      if (o.framed) return lines.join('\n');
      const head = `${document.title || 'Untitled'} — ${location.href}\n${where()}`;
      if (more) lines.push(`… ${more} more (--max for more, --viewport for just what's visible)`);
      if (!lines.length) lines.push('(nothing to read or use)');
      return head + '\n\n' + lines.join('\n');
    }
    function read(o) {
      o = o || {};
      const root = o.all ? document.body : (document.querySelector('main,[role=main],article') || document.body);
      let t = (root?.innerText || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
      const max = o.max || 6000;
      if (t.length > max) t = t.slice(0, max) + `\n… ${t.length - max} more characters (--max for more)`;
      return `${document.title || 'Untitled'} — ${location.href}\n\n${t}`;
    }
    function find(q) {
      q = q.toLowerCase();
      const out = [], seen = new Set();
      const all = document.body ? document.body.querySelectorAll('*') : [];
      for (const el of all) {
        if (SKIP.has(el.tagName) || out.length >= 20) continue;
        const own = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join(' ');
        const attrs = [el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('title'), el.getAttribute('alt'), el.value].join(' ');
        if (!(own + ' ' + attrs).toLowerCase().includes(q) || !shown(el)) continue;
        const target = el.closest(ACT) || el;
        if (seen.has(target)) continue;
        seen.add(target);
        out.push(target.matches(ACT) ? describe(target) : `[${ref(target)}] ${target.tagName.toLowerCase()} "${clean(target.innerText, 80)}"`);
      }
      return out.length ? out.join('\n') : `Nothing on the page says "${q}".`;
    }
    function short(el) {
      let s = el.tagName.toLowerCase();
      if (el.id) s += '#' + el.id;
      else if (typeof el.className === 'string' && el.className.trim()) s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
      const t = clean(el.innerText, 40); if (t) s += ` "${t}"`;
      return s;
    }
    function point(r) {
      const el = get(r);
      // Same-site frames: the frame comes into view first, then the element in it.
      for (let w = el.ownerDocument.defaultView; w && w.frameElement; w = w.parent) w.frameElement.scrollIntoView({ block: 'nearest', behavior: 'instant' });
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const win = el.ownerDocument.defaultView;
      let aim = el, b = el.getBoundingClientRect();
      const unseen = b.width < 2 || b.height < 2 || b.right <= 0 || b.bottom <= 0 || b.left >= win.innerWidth
        || b.top >= win.innerHeight || getComputedStyle(el).opacity === '0';
      const shownLabel = unseen && el.labels && Array.from(el.labels).find(shown);
      if (shownLabel) {
        aim = shownLabel;
        aim.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        b = aim.getBoundingClientRect();
      }
      const lx = Math.min(Math.max(b.left + b.width / 2, 1), win.innerWidth - 1), ly = Math.min(Math.max(b.top + b.height / 2, 1), win.innerHeight - 1);
      const hit = el.ownerDocument.elementFromPoint(lx, ly);
      const ours = hit && (hit === aim || aim.contains(hit) || hit.contains(aim) || (el.labels && Array.from(el.labels).includes(hit)));
      const covered = hit && !ours ? short(hit) : '';
      let x = lx, y = ly;
      for (let w = win; w && w.frameElement; w = w.parent) { const f = w.frameElement, fb = f.getBoundingClientRect(); x += fb.left + f.clientLeft; y += fb.top + f.clientTop; }
      const disabled = !!(el.disabled || el.getAttribute('aria-disabled') === 'true');
      return { x, y, covered, label: describe(el), disabled, checked: toggled(el) };
    }
    function toggled(el) {
      const ro = role(el);
      if (!['checkbox', 'switch', 'menuitemcheckbox'].includes(ro)) return null;
      return !!(el.checked || el.getAttribute('aria-checked') === 'true');
    }
    const state = r => { const el = get(r); return { label: describe(el), checked: toggled(el) }; };
    function scrollPage(o) {
      const page = document.scrollingElement || document.documentElement;
      const room = el => {
        const s = getComputedStyle(el), y = o.dy !== 0;
        if (!/(auto|scroll|overlay)/.test(y ? s.overflowY : s.overflowX)) return false;
        const pos = y ? el.scrollTop : el.scrollLeft, span = y ? el.scrollHeight - el.clientHeight : el.scrollWidth - el.clientWidth;
        return span > 1 && ((y ? o.dy : o.dx) > 0 ? pos < span - 1 : pos > 0);
      };
      let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
      while (el && el !== page && !room(el)) el = el.parentElement;
      const box = el || page;
      box.scrollBy({ left: o.dx, top: o.dy, behavior: 'instant' });
      if (box === page) return where();
      const max = box.scrollHeight - box.clientHeight;
      return `scrolled ${Math.round(box.scrollTop)} of ${max} px in ${short(box)}`;
    }
    function focus(o) {
      const el = get(o.ref);
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      el.focus();
      if (o.select) {
        if (typeof el.select === 'function' && el.tagName !== 'SELECT') el.select();
        else if (el.isContentEditable) { const range = document.createRange(); range.selectNodeContents(el); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); }
      } else if (typeof el.setSelectionRange === 'function') { try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {} }
      return describe(el);
    }
    function choose(o) {
      const el = get(o.ref);
      if (el.tagName !== 'SELECT') throw new Error(`${describe(el)} isn't a list to choose from; click it instead.`);
      const want = o.value.toLowerCase();
      const opt = Array.from(el.options).find(op => op.value.toLowerCase() === want || clean(op.text).toLowerCase() === want) || Array.from(el.options).find(op => clean(op.text).toLowerCase().includes(want));
      if (!opt) throw new Error(`No option "${o.value}". Options: ${Array.from(el.options).map(op => clean(op.text, 30)).slice(0, 20).join(', ')}`);
      el.value = opt.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return `chose "${clean(opt.text)}" in ${describe(el)}`;
    }
    function reveal(r) { const el = get(r); el.scrollIntoView({ block: 'center', behavior: 'instant' }); return `showing ${describe(el)}; ${where()}`; }
    const viewport = () => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio, scrollX, scrollY, page: document.documentElement.scrollHeight });
    const contains = t => (document.body?.innerText || '').toLowerCase().includes(t.toLowerCase());
    const position = () => where();
    const label = r => describe(get(r));
    const frameNumber = el => S.frames.indexOf(el) + 1;
    function frameBox(n) {
      const el = S.frames[n - 1];
      if (!el || !el.isConnected) throw new Error(`No frame f${n} now. Run \`mbga snapshot\` for fresh refs.`);
      el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
      const b = el.getBoundingClientRect();
      return { x: b.left + el.clientLeft, y: b.top + el.clientTop };
    }
    Object.defineProperty(window, '__mbga', { value: {
      snapshot, read, find, point, state, scrollPage, focus, choose, reveal, viewport, contains, position, label, frameNumber, frameBox,
    } });
    })();
    """#
}
