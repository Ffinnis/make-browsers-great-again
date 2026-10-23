import AppKit

@MainActor
final class ConsoleMessage {
    enum Level: Int { case verbose, info, warning, error }
    enum Kind { case log, command, result, navigation }

    let id: Int
    let kind: Kind
    let level: Level
    let type: String
    let args: [JSON]
    let text: String
    let url: String
    let line: Int
    let column: Int
    let stack: [JSON]
    let timestamp: Date
    let depth: Int
    let group: Int?
    var repeats = 1
    var exceptionID: Int?

    init(id: Int, kind: Kind, level: Level, type: String, args: [JSON], text: String, url: String, line: Int, column: Int,
         stack: [JSON], timestamp: Date = Date(), depth: Int, group: Int?) {
        self.id = id
        self.kind = kind
        self.level = level
        self.type = type
        self.args = args
        self.text = text
        self.url = url
        self.line = line
        self.column = column
        self.stack = stack
        self.timestamp = timestamp
        self.depth = depth
        self.group = group
    }

    var isGroupStart: Bool { type == "startGroup" || type == "startGroupCollapsed" }

    func repeats(_ other: ConsoleMessage) -> Bool {
        kind == .log && other.kind == .log && type == other.type && level == other.level && url == other.url
            && line == other.line && column == other.column && !isGroupStart && args.count == other.args.count
            && plain == other.plain && args.allSatisfy { $0.str("objectId") == nil }
    }

    lazy var plain: String = ConsoleFormat.message(self).string
}

@MainActor
final class ConsoleModel: InspectorModel {
    private weak var session: InspectorSession?
    private(set) var messages: [ConsoleMessage] = []
    let changed = Signal<Void>()
    var preserveLog = UserDefaults.standard.bool(forKey: "inspector.console.preserve") {
        didSet { UserDefaults.standard.set(preserveLog, forKey: "inspector.console.preserve") }
    }
    var collapsedGroups: Set<Int> = []
    private var nextID = 0
    private var groups: [Int] = []
    private static let limit = 5000

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session else { return }
        session.on("Runtime.consoleAPICalled", self) { [weak self] _, params in self?.consoleCalled(params) }
        session.on("Runtime.exceptionThrown", self) { [weak self] _, params in self?.exceptionThrown(params) }
        session.on("Runtime.exceptionRevoked", self) { [weak self] _, params in
            guard let self, let id = params.int("exceptionId") else { return }
            messages.removeAll { $0.exceptionID == id }
            changed.send()
        }
        session.on("Log.entryAdded", self) { [weak self] _, params in self?.logEntry(params) }
        session.navigated.observe(self) { [weak self] url in
            guard let self else { return }
            if preserveLog {
                add(kind: .navigation, level: .info, type: "log", args: [], text: "Navigated to \(url)")
            } else {
                clear(local: true)
            }
        }
        session.call("Log.enable")
    }

    func stop() {
        session?.call("Log.disable")
    }

    var errorCount: Int {
        messages.filter { $0.level == .error && $0.kind == .log }.reduce(0) { $0 + $1.repeats }
    }

    func clear(local: Bool = false) {
        messages = []
        groups = []
        collapsedGroups = []
        if !local { session?.call("Runtime.discardConsoleEntries") }
        changed.send()
    }

    private func consoleCalled(_ params: JSON) {
        let type = params.str("type") ?? "log"
        let args = params.list("args")
        if type == "debug", args.first?.str("value")?.hasPrefix("__mbga_") == true { return }
        let frame = params.obj("stackTrace")?.list("callFrames").first
        let level: ConsoleMessage.Level = switch type {
        case "error", "assert": .error
        case "warning": .warning
        case "debug": .verbose
        default: .info
        }
        switch type {
        case "clear":
            clear(local: true)
            add(kind: .log, level: .info, type: "log", args: [], text: "Console was cleared")
            return
        case "endGroup":
            if !groups.isEmpty { groups.removeLast() }
            return
        case "assert" where args.isEmpty:
            add(kind: .log, level: level, type: type, args: [], text: "Assertion failed", frame: frame, params: params)
            return
        default:
            break
        }
        var shownArgs = args
        if type == "assert" { shownArgs.insert(["type": "string", "value": "Assertion failed:"], at: 0) }
        add(kind: .log, level: level, type: type, args: shownArgs, text: "", frame: frame, params: params)
    }

    private func exceptionThrown(_ params: JSON) {
        guard let details = params.obj("exceptionDetails") else { return }
        let frame = details.obj("stackTrace")?.list("callFrames").first
        var text = details.str("text") ?? "Uncaught"
        var args: [JSON] = []
        if let exception = details.obj("exception") {
            if exception.str("subtype") == "error" || exception.str("className")?.hasSuffix("Error") == true {
                text = "\(text.hasPrefix("Uncaught") ? "Uncaught " : "")\(exception.str("description") ?? "")"
                    .replacingOccurrences(of: "Uncaught (in promise) ", with: "Uncaught (in promise) ")
                if details.str("text")?.contains("in promise") == true, !text.contains("in promise") {
                    text = text.replacingOccurrences(of: "Uncaught ", with: "Uncaught (in promise) ")
                }
            } else {
                args = [exception]
            }
        }
        let message = make(kind: .log, level: .error, type: "error", args: args, text: text,
                           url: frame?.str("url") ?? details.str("url") ?? "",
                           line: frame?.int("lineNumber") ?? details.int("lineNumber") ?? 0,
                           column: frame?.int("columnNumber") ?? details.int("columnNumber") ?? 0,
                           stack: details.obj("stackTrace")?.list("callFrames") ?? [])
        message.exceptionID = details.int("exceptionId")
        append(message)
    }

    private func logEntry(_ params: JSON) {
        guard let entry = params.obj("entry") else { return }
        if entry.str("source") == "javascript" || entry.str("source") == "console-api" { return }
        let level: ConsoleMessage.Level = switch entry.str("level") {
        case "error": .error
        case "warning": .warning
        case "verbose": .verbose
        default: .info
        }
        var text = entry.str("text") ?? ""
        if let url = entry.str("url"), entry.str("source") == "network", !text.contains(url) {
            text = "\(text) \(url)"
        }
        append(make(kind: .log, level: level, type: "log", args: entry.list("args"), text: text,
                    url: entry.str("url") ?? "", line: entry.int("lineNumber") ?? 0, column: 0,
                    stack: entry.obj("stackTrace")?.list("callFrames") ?? []))
    }

    private func add(kind: ConsoleMessage.Kind, level: ConsoleMessage.Level, type: String, args: [JSON], text: String,
                     frame: JSON? = nil, params: JSON? = nil) {
        let stack = params?.obj("stackTrace")?.list("callFrames") ?? []
        let message = make(kind: kind, level: level, type: type, args: args, text: text, url: frame?.str("url") ?? "",
                           line: frame?.int("lineNumber") ?? 0, column: frame?.int("columnNumber") ?? 0,
                           stack: type == "trace" || level == .error || level == .warning ? stack : [])
        append(message)
        if message.isGroupStart {
            groups.append(message.id)
            if type == "startGroupCollapsed" { collapsedGroups.insert(message.id) }
        }
    }

    private func make(kind: ConsoleMessage.Kind, level: ConsoleMessage.Level, type: String, args: [JSON], text: String,
                      url: String, line: Int, column: Int, stack: [JSON]) -> ConsoleMessage {
        nextID += 1
        return ConsoleMessage(id: nextID, kind: kind, level: level, type: type, args: args, text: text, url: url, line: line,
                              column: column, stack: stack, depth: groups.count, group: groups.last)
    }

    private func append(_ message: ConsoleMessage) {
        if let last = messages.last, last.repeats(message) {
            last.repeats += 1
        } else {
            messages.append(message)
            if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
        }
        changed.send()
    }

    static var history: [String] = UserDefaults.standard.stringArray(forKey: "inspector.console.history") ?? [] {
        didSet {
            guard InspectorSettings.debugPanel == nil else { return }
            UserDefaults.standard.set(Array(history.suffix(200)), forKey: "inspector.console.history")
        }
    }

    func evaluate(_ expression: String) {
        guard let session, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if Self.history.last != expression { Self.history.append(expression) }
        append(make(kind: .command, level: .info, type: "log", args: [], text: expression, url: "", line: 0, column: 0, stack: []))
        Task {
            let result = try? await run(expression, in: session, preview: false)
            guard let result else { return }
            if let details = result.obj("exceptionDetails") {
                let exception = details.obj("exception")
                let text = exception?.str("description") ?? details.str("text") ?? "Error"
                append(make(kind: .result, level: .error, type: "error", args: [],
                            text: "Uncaught " + text.replacingOccurrences(of: "Uncaught ", with: ""),
                            url: "", line: 0, column: 0, stack: details.obj("stackTrace")?.list("callFrames") ?? []))
            } else if let object = result.obj("result") {
                append(make(kind: .result, level: .info, type: "log", args: [object], text: "", url: "", line: 0, column: 0, stack: []))
            }
        }
    }

    func preview(_ expression: String) async -> JSON? {
        guard let session, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let result = try? await run(expression, in: session, preview: true), result["exceptionDetails"] == nil else { return nil }
        return result.obj("result")
    }

    private func run(_ expression: String, in session: InspectorSession, preview: Bool) async throws -> JSON {
        var params: JSON = ["expression": expression, "includeCommandLineAPI": true, "generatePreview": true,
                            "objectGroup": preview ? "preview" : "console"]
        if preview {
            params["throwOnSideEffect"] = true
            params["timeout"] = 500
        }
        if let frame = session.existing(SourcesModel.self)?.selectedCallFrameID {
            params["callFrameId"] = frame
            return try await session.send("Debugger.evaluateOnCallFrame", params, timeout: preview ? 2 : 3600)
        }
        params["replMode"] = true
        params["userGesture"] = !preview
        params["awaitPromise"] = !preview
        if let context = session.mainContextID { params["contextId"] = context }
        return try await session.send("Runtime.evaluate", params, timeout: preview ? 2 : 3600)
    }

    func completions(for text: String) async -> (prefix: String, names: [String]) {
        guard let session else { return ("", []) }
        let tail = String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }.reversed())
        let before = text.dropLast(tail.count)
        var target = "globalThis"
        if before.hasSuffix(".") {
            let head = before.dropLast()
            var depth = 0, start = head.endIndex
            for index in head.indices.reversed() {
                let char = head[index]
                if char == ")" || char == "]" { depth += 1 } else if char == "(" || char == "[" {
                    if depth == 0 { break }
                    depth -= 1
                } else if depth == 0, " ;,=+-*/!&|?:{}<>\n\t".contains(char) { break }
                start = index
            }
            target = String(head[start...])
            guard !target.isEmpty else { return (tail, []) }
        } else if before.last.map({ $0.isLetter || $0.isNumber || $0 == "\"" || $0 == "'" }) == true {
            return (tail, [])
        }
        let function = "(function(o){const s=new Set();for(let i=0;o!=null&&i<20;o=Object.getPrototypeOf(o),i++){try{for(const k of Object.getOwnPropertyNames(o))s.add(k)}catch(e){}}return [...s]})"
        var params: JSON = ["expression": "\(function)(\(target))", "returnByValue": true, "throwOnSideEffect": target != "globalThis",
                            "includeCommandLineAPI": true, "timeout": 500, "objectGroup": "completion"]
        if let context = session.mainContextID { params["contextId"] = context }
        var names: [String] = []
        if let frame = session.existing(SourcesModel.self)?.selectedCallFrameID {
            params["callFrameId"] = frame
            params["contextId"] = nil
            names = ((try? await session.send("Debugger.evaluateOnCallFrame", params))?.obj("result")?["value"] as? [String]) ?? []
        } else {
            names = ((try? await session.send("Runtime.evaluate", params))?.obj("result")?["value"] as? [String]) ?? []
        }
        if target == "globalThis" {
            let lexical = (try? await session.send("Runtime.globalLexicalScopeNames"))?["names"] as? [String] ?? []
            names += lexical
            names += ["await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
                      "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof",
                      "let", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
                      "var", "void", "while", "yield", "$0", "$_", "$", "$$", "$x", "copy", "clear", "dir", "inspect",
                      "keys", "values", "monitorEvents", "getEventListeners", "queryObjects"]
        }
        let lower = tail.lowercased()
        let matches = Set(names).filter { $0 != tail && (tail.isEmpty || $0.lowercased().hasPrefix(lower)) && !$0.contains(" ") }
        let sorted = matches.sorted { a, b in
            let (ua, ub) = (a.hasPrefix("_"), b.hasPrefix("_"))
            if ua != ub { return !ua }
            let (pa, pb) = (a.hasPrefix(tail), b.hasPrefix(tail))
            if pa != pb { return pa }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return (tail, Array(sorted.prefix(200)))
    }
}

@MainActor
enum ConsoleFormat {
    static func message(_ message: ConsoleMessage) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = InspectorTheme.mono(11)
        let color: NSColor = message.level == .error ? InspectorTheme.error
            : message.level == .warning ? InspectorTheme.warning
            : message.kind == .navigation ? InspectorTheme.link : .labelColor
        if message.kind == .command {
            return SyntaxColorer.color(message.text, as: .javascript, font: font)
        }
        if !message.text.isEmpty { out.add(message.text, color, font: font) }
        if message.type == "table", let table = table(message.args.first) {
            return table
        }
        var args = message.args[...]
        if let first = args.first, first.str("type") == "string", let format = first.str("value"), format.contains("%"),
           message.kind == .log {
            args = args.dropFirst()
            out.append(substitute(format, args: &args, color: color, font: font))
        }
        for arg in args {
            if out.length > 0 { out.add(" ", color, font: font) }
            if arg.str("type") == "string" {
                let value = (arg.str("value") ?? "").clipped(10000)
                if message.kind == .result {
                    out.add("\"\(value)\"", InspectorTheme.string, font: font)
                } else {
                    out.add(value, color, font: font)
                }
            } else if arg.str("subtype") == "error" {
                out.add(arg.str("description") ?? "Error", color, font: font)
            } else {
                out.add(RemoteValue.summary(arg).clipped(2000), arg.str("type") == "object" && message.level == .info ? .labelColor : RemoteValue.color(arg), font: font)
            }
        }
        return out
    }

    private static func substitute(_ format: String, args: inout ArraySlice<JSON>, color: NSColor, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var current = color
        var text = ""
        var chars = format[...]
        func flush() {
            if !text.isEmpty { out.add(text, current, font: font); text = "" }
        }
        while let char = chars.first {
            chars = chars.dropFirst()
            guard char == "%", let spec = chars.first else { text.append(char); continue }
            switch spec {
            case "%":
                text.append("%")
                chars = chars.dropFirst()
            case "s", "d", "i", "f", "o", "O", "c":
                chars = chars.dropFirst()
                guard let arg = args.first else { text.append("%"); text.append(spec); continue }
                args = args.dropFirst()
                switch spec {
                case "s": text += arg.str("type") == "string" ? arg.str("value") ?? "" : RemoteValue.summary(arg)
                case "d", "i":
                    let number = arg.num("value") ?? Double(arg.str("value") ?? "") ?? .nan
                    text += number.isNaN ? "NaN" : "\(Int(number))"
                case "f": text += arg.num("value").map { "\($0)" } ?? "NaN"
                case "c":
                    flush()
                    current = cssColor(arg.str("value") ?? "") ?? color
                default:
                    flush()
                    out.add(RemoteValue.summary(arg), RemoteValue.color(arg), font: font)
                }
            default:
                text.append("%")
            }
        }
        flush()
        return out
    }

    private static func cssColor(_ style: String) -> NSColor? {
        guard let range = style.range(of: #"(?:^|;)\s*color\s*:\s*([^;]+)"#, options: .regularExpression) else { return nil }
        let value = style[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let named: [String: NSColor] = ["red": .systemRed, "green": .systemGreen, "blue": .systemBlue, "orange": .systemOrange,
                                        "purple": .systemPurple, "gray": .systemGray, "grey": .systemGray, "yellow": .systemYellow]
        if let color = named[value] { return color }
        if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return nil
    }

    private static func table(_ arg: JSON?) -> NSAttributedString? {
        guard let preview = arg?.obj("preview") else { return nil }
        let rows = preview.list("properties")
        guard !rows.isEmpty else { return nil }
        var columns: [String] = []
        var cells: [[String: String]] = []
        for row in rows {
            var cell: [String: String] = [:]
            if let nested = row.obj("valuePreview") {
                for property in nested.list("properties") {
                    let name = property.str("name") ?? ""
                    if !columns.contains(name) { columns.append(name) }
                    cell[name] = property.str("type") == "string" ? "\"\(property.str("value") ?? "")\"" : property.str("value") ?? ""
                }
            } else {
                if !columns.contains("Value") { columns.append("Value") }
                cell["Value"] = row.str("value") ?? ""
            }
            cell["(index)"] = row.str("name") ?? ""
            cells.append(cell)
        }
        let header = ["(index)"] + columns
        let widths = header.map { name in max(name.count, cells.map { ($0[name] ?? "").count }.max() ?? 0).clamped(to: 3...24) }
        func line(_ values: [String]) -> String {
            zip(values, widths).map { $0.clipped($1 - 1).padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: " │ ")
        }
        let out = NSMutableAttributedString()
        out.add(line(header) + "\n", .secondaryLabelColor, font: InspectorTheme.mono(11, .semibold))
        out.add(widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─") + "\n", .tertiaryLabelColor, font: InspectorTheme.mono(11))
        for (i, cell) in cells.enumerated() {
            out.add(line(header.map { cell[$0] ?? "" }) + (i == cells.count - 1 ? "" : "\n"), .labelColor, font: InspectorTheme.mono(11))
        }
        return out
    }

    static func location(_ message: ConsoleMessage) -> String? {
        guard !message.url.isEmpty else { return nil }
        var name = URL(string: message.url)?.lastPathComponent ?? message.url
        if name.isEmpty || name == "/" { name = URL(string: message.url)?.host ?? message.url }
        return "\(name.clipped(28)):\(message.line + 1)"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

final class ConsolePanel: InspectorPanelView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let toolbar = InspectorToolbar()
    private let clearButton = InspectorButton("nosign", tip: "Clear console  ⌘K")
    private let filter = InspectorFilterField(placeholder: "Filter")
    private let levels = InspectorChips(["All", "Errors", "Warnings", "Info", "Verbose"])
    private let preserve = InspectorButton("pin", tip: "Preserve log across page loads")
    private let counts = Label.make("", size: 11, color: .secondaryLabelColor)
    private let outline = InspectorOutlineView()
    private let scroll = NSScrollView()
    private let prompt = ConsolePrompt()
    private let empty = InspectorEmptyView("Messages the page logs show here.\nType JavaScript below to run it in the page.")
    private var model: ConsoleModel?
    private var shown: [ConsoleMessage] = []
    private var heights: [Int: CGFloat] = [:]
    private var heightWidth: CGFloat = 0
    private lazy var reload = Coalescer { [weak self] in self?.reloadMessages() }
    private var filterText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        clearButton.action = { [weak self] in self?.model?.clear() }
        preserve.action = { [weak self] in
            guard let self, let model else { return }
            model.preserveLog.toggle()
            preserve.isOn = model.preserveLog
        }
        filter.onChange = { [weak self] text in
            self?.filterText = text
            self?.reload.flush()
        }
        levels.multiple = true
        levels.onChange = { [weak self] _ in self?.reload.flush() }
        toolbar.add(clearButton, width: 24)
        toolbar.add(preserve, width: 24)
        toolbar.addSeparator()
        toolbar.add(filter, width: nil)
        toolbar.add(levels, width: levels.preferredWidth)
        toolbar.add(counts, width: 64, trailing: true)
        addSubview(toolbar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.intercellSpacing = .zero
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menuForRow = { [weak self] row in self?.menu(row) }
        outline.onKey = { [weak self] event in self?.key(event) ?? false }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.postsFrameChangedNotifications = true
        addSubview(scroll)
        addSubview(empty)
        prompt.onRun = { [weak self] text in self?.run(text) }
        prompt.onClear = { [weak self] in self?.model?.clear() }
        prompt.onResize = { [weak self] in self?.needsLayout = true }
        addSubview(prompt)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        levels.isHidden = bounds.width < 470
        let promptHeight = prompt.preferredHeight
        prompt.frame = NSRect(x: 0, y: bounds.height - promptHeight, width: bounds.width, height: promptHeight)
        let list = NSRect(x: 0, y: toolbar.frame.maxY, width: bounds.width, height: max(prompt.frame.minY - toolbar.frame.maxY, 0))
        scroll.frame = list
        empty.frame = list
        if abs(heightWidth - list.width) > 0.5 {
            heightWidth = list.width
            heights = [:]
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }

    override func sessionChanged() {
        model?.changed.stopObserving(self)
        model = session?.model(ConsoleModel.self)
        model?.changed.observe(self) { [weak self] in self?.reload.schedule() }
        prompt.model = model
        preserve.isOn = model?.preserveLog ?? false
        heights = [:]
        reloadMessages(scrollToEnd: true)
    }

    override func panelDidAppear() {
        reloadMessages(scrollToEnd: true)
        window?.makeFirstResponder(prompt.textView)
    }

    override func focusFilter() { window?.makeFirstResponder(filter) }

    private func visible(_ message: ConsoleMessage, levels selected: Set<Int>) -> Bool {
        if let group = message.group, isHidden(group: group) { return false }
        if !selected.contains(0), message.kind == .log {
            let index = switch message.level {
            case .error: 1
            case .warning: 2
            case .info: 3
            case .verbose: 4
            }
            if !selected.contains(index) { return false }
        } else if selected.contains(0), message.level == .verbose, message.kind == .log {
            return false
        }
        guard !filterText.isEmpty else { return true }
        if filterText.hasPrefix("-") {
            let term = String(filterText.dropFirst())
            return term.isEmpty || !message.plain.localizedCaseInsensitiveContains(term) && !message.url.localizedCaseInsensitiveContains(term)
        }
        return message.plain.localizedCaseInsensitiveContains(filterText) || message.url.localizedCaseInsensitiveContains(filterText)
    }

    private func isHidden(group: Int) -> Bool {
        guard let model else { return false }
        if model.collapsedGroups.contains(group) { return true }
        if let parent = model.messages.first(where: { $0.id == group })?.group { return isHidden(group: parent) }
        return false
    }

    private func reloadMessages(scrollToEnd: Bool = false) {
        let atEnd = scrollToEnd || isScrolledToEnd
        let selected = levels.selected
        let previous = shown
        shown = (model?.messages ?? []).filter { visible($0, levels: selected) }
        let errors = model?.messages.filter { $0.level == .error && $0.kind == .log }.reduce(0) { $0 + $1.repeats } ?? 0
        let warnings = model?.messages.filter { $0.level == .warning }.reduce(0) { $0 + $1.repeats } ?? 0
        counts.attributedStringValue = countsText(errors: errors, warnings: warnings)
        empty.isHidden = !(model?.messages.isEmpty ?? true)
        if previous.count <= shown.count, zip(previous, shown).allSatisfy({ $0 === $1 }), !previous.isEmpty {
            let added = shown.count - previous.count
            if added > 0 { outline.insertItems(at: IndexSet(integersIn: previous.count..<shown.count), inParent: nil) }
            if let last = previous.last {
                heights[last.id] = nil
                outline.reloadItem(last)
                let row = outline.row(forItem: last)
                if row >= 0 { outline.noteHeightOfRows(withIndexesChanged: [row]) }
            }
        } else {
            outline.reloadData()
        }
        if atEnd { scrollToEndNow() }
    }

    private func countsText(errors: Int, warnings: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if errors > 0 { text.add("✕ \(errors)", InspectorTheme.error, font: Theme.font(11, .medium)) }
        if warnings > 0 { text.add("\(errors > 0 ? "  " : "")⚠ \(warnings)", InspectorTheme.warning, font: Theme.font(11, .medium)) }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    private var isScrolledToEnd: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= outline.frame.height - 30
    }

    private func scrollToEndNow() {
        outline.layoutSubtreeIfNeeded()
        let rows = outline.numberOfRows
        if rows > 0 { outline.scrollRowToVisible(rows - 1) }
    }

    private func run(_ text: String) {
        model?.evaluate(text)
        DispatchQueue.main.async { [weak self] in self?.scrollToEndNow() }
    }

    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let point = outline.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if let message = outline.item(atRow: row) as? ConsoleMessage {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConsoleMessageCell,
               cell.linkHit(cell.convert(point, from: outline)) {
                session?.revealSource(url: message.url, line: message.line, column: message.column)
                return
            }
            if message.isGroupStart, let model {
                if model.collapsedGroups.contains(message.id) { model.collapsedGroups.remove(message.id) } else { model.collapsedGroups.insert(message.id) }
                reloadMessages()
                return
            }
            if outline.isExpandable(message) {
                if outline.isItemExpanded(message) { outline.collapseItem(message) } else { expand(message) }
            }
        } else if let frame = outline.item(atRow: row) as? StackFrameItem {
            session?.revealSource(url: frame.url, line: frame.line, column: frame.column)
        } else if let node = outline.item(atRow: row) as? ValueNode, node.isExpandable {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { expand(node) }
        }
    }

    private func expand(_ item: Any) {
        if let node = item as? ValueNode, node.children == nil {
            node.load { [weak self] in
                self?.outline.reloadItem(node, reloadChildren: true)
                self?.outline.expandItem(node)
            }
        } else {
            outline.expandItem(item)
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copySelection()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k" {
            model?.clear()
            return true
        }
        if let chars = event.characters, !chars.isEmpty, event.modifierFlags.isDisjoint(with: [.command, .control]),
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) }) {
            window?.makeFirstResponder(prompt.textView)
            prompt.textView.keyDown(with: event)
            return true
        }
        return false
    }

    private func copySelection() {
        let lines = outline.selectedRowIndexes.compactMap { row -> String? in
            let item = outline.item(atRow: row)
            if let message = item as? ConsoleMessage { return message.plain }
            if let node = item as? ValueNode { return node.name.isEmpty ? node.copyText : "\(node.name): \(node.copyText)" }
            if let frame = item as? StackFrameItem { return frame.title }
            return nil
        }
        if !lines.isEmpty { Format.copy(lines.joined(separator: "\n")) }
    }

    private func menu(_ row: Int) -> NSMenu? {
        let menu = NSMenu()
        let item = outline.item(atRow: row)
        menu.add("Copy") { [weak self] in self?.copySelection() }
        if let message = item as? ConsoleMessage {
            if let object = message.args.first(where: { $0.str("objectId") != nil }), let session {
                menu.add("Copy Object") {
                    Task {
                        let result = try? await session.send("Runtime.callFunctionOn", [
                            "objectId": object.str("objectId")!, "returnByValue": true,
                            "functionDeclaration": "function(){ try { return JSON.stringify(this, null, 2) } catch (e) { return String(this) } }",
                        ])
                        if let text = result?.obj("result")?.str("value") { Format.copy(text) }
                    }
                }
                menu.add("Store as Global Variable") { [weak self] in self?.storeGlobal(object) }
                if object.str("subtype") == "node" {
                    menu.add("Reveal in Elements") {
                        Task {
                            let node = try? await session.send("DOM.describeNode", ["objectId": object.str("objectId")!])
                            if let id = node?.obj("node")?.int("backendNodeId") { session.revealNode(backendNodeID: id) }
                        }
                    }
                }
            }
            if !message.url.isEmpty {
                menu.add("Open \(ConsoleFormat.location(message) ?? "Source")") { [weak self] in
                    self?.session?.revealSource(url: message.url, line: message.line, column: message.column)
                }
                menu.add("Copy Link Address") { Format.copy(message.url) }
            }
        } else if let node = item as? RemoteValueNode {
            menu.add("Store as Global Variable") { [weak self] in self?.storeGlobal(node.object) }
        }
        menu.addItem(.separator())
        menu.add("Clear Console") { [weak self] in self?.model?.clear() }
        menu.add("Save As…") { [weak self] in self?.save() }
        return menu
    }

    private func storeGlobal(_ object: JSON) {
        guard let session, let id = object.str("objectId") else { return }
        Task {
            let result = try? await session.send("Runtime.callFunctionOn", [
                "objectId": id, "returnByValue": true,
                "functionDeclaration": "function(){ let i = 1; while (('temp' + i) in globalThis) i++; globalThis['temp' + i] = this; return 'temp' + i }",
            ])
            if let name = result?.obj("result")?.str("value") { model?.evaluate(name) }
        }
    }

    private func save() {
        guard let model, let window else { return }
        let panel = NSSavePanel()
        let host = URL(string: session?.url ?? "")?.host ?? "page"
        panel.nameFieldStringValue = "\(host)-console.log"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let text = model.messages.map { message in
                let place = ConsoleFormat.location(message).map { "  \($0)" } ?? ""
                return "\(message.plain)\(message.repeats > 1 ? " (×\(message.repeats))" : "")\(place)"
            }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: shown.count
        case let message as ConsoleMessage: children(of: message).count
        case let node as ValueNode: node.children?.count ?? 0
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: shown[index]
        case let message as ConsoleMessage: children(of: message)[index]
        case let node as ValueNode: node.children![index]
        default: NSNull()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case let message as ConsoleMessage: !children(of: message).isEmpty
        case let node as ValueNode: node.isExpandable
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? ValueNode, node.children == nil else { return true }
        expand(node)
        return false
    }

    private var childCache: [Int: [AnyObject]] = [:]
    private func children(of message: ConsoleMessage) -> [AnyObject] {
        if let cached = childCache[message.id] { return cached }
        var items: [AnyObject] = []
        let objects = message.args.filter { RemoteValue.isExpandable($0) && $0.str("subtype") != "error" }
        if message.level == .error || message.type == "trace" || message.level == .warning, !message.stack.isEmpty, objects.isEmpty {
            items = message.stack.map { StackFrameItem($0) }
        } else {
            items = objects.map { RemoteValueNode(name: "", object: $0, session: session) }
        }
        childCache[message.id] = items
        return items
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let message = item as? ConsoleMessage else { return 18 }
        if let height = heights[message.id] { return height }
        let height = ConsoleMessageCell.height(for: message, width: heightWidth, indent: CGFloat(message.depth) * 14)
        heights[message.id] = height
        return height
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let message as ConsoleMessage:
            let id = NSUserInterfaceItemIdentifier("console.message")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ConsoleMessageCell ?? {
                let cell = ConsoleMessageCell()
                cell.identifier = id
                return cell
            }()
            cell.configure(message, collapsed: model?.collapsedGroups.contains(message.id) ?? false)
            return cell
        case let frame as StackFrameItem:
            let text = NSMutableAttributedString()
            text.add("at ", .tertiaryLabelColor, font: InspectorTheme.mono(10.5))
            text.add(frame.function + " ", .secondaryLabelColor, font: InspectorTheme.mono(10.5))
            text.add("(\(frame.place))", InspectorTheme.link, font: InspectorTheme.mono(10.5))
            return InspectorTable.cell(outlineView, "frame", text)
        case let node as ValueNode:
            let text = NSMutableAttributedString()
            if !node.name.isEmpty {
                text.add(node.name, node.dimmed ? InspectorTheme.property.withAlphaComponent(0.6) : InspectorTheme.property, font: InspectorTheme.mono(11))
                text.add(": ", .secondaryLabelColor, font: InspectorTheme.mono(11))
            }
            text.append(node.valueText())
            return InspectorTable.cell(outlineView, "value", text)
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ConsoleRowView()
        if let message = item as? ConsoleMessage {
            row.fill = message.level == .error ? InspectorTheme.errorFill : message.level == .warning ? InspectorTheme.warningFill : nil
            row.separator = true
        }
        return row
    }
}

private final class StackFrameItem {
    let function: String
    let url: String
    let line: Int
    let column: Int

    init(_ frame: JSON) {
        function = (frame.str("functionName")).flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)"
        url = frame.str("url") ?? ""
        line = frame.int("lineNumber") ?? 0
        column = frame.int("columnNumber") ?? 0
    }

    var place: String {
        let name = URL(string: url)?.lastPathComponent ?? url
        return "\(name.isEmpty ? url : name):\(line + 1):\(column + 1)"
    }

    var title: String { "at \(function) (\(place))" }
}

private final class ConsoleRowView: InspectorRowView {
    var separator = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard separator else { return }
        InspectorTheme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

private final class ConsoleMessageCell: NSTableCellView {
    private let icon = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let link = NSTextField(labelWithString: "")
    private let badge = Label.chip()
    private static let linkWidth: CGFloat = 110
    private var indent: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        text.isSelectable = false
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byCharWrapping
        text.cell?.wraps = true
        addSubview(text)
        link.font = InspectorTheme.mono(10.5)
        link.textColor = InspectorTheme.link
        link.alignment = .right
        link.lineBreakMode = .byTruncatingHead
        addSubview(link)
        badge.font = Theme.font(10, .semibold)
        badge.layer?.cornerRadius = 7
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func textWidth(_ width: CGFloat, indent: CGFloat, link: Bool, repeats: Int) -> CGFloat {
        max(width - indent - 22 - (repeats > 1 ? 24 : 0) - (link ? linkWidth + 12 : 8), 40)
    }

    private static let measure: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        return field
    }()

    static func height(for message: ConsoleMessage, width: CGFloat, indent: CGFloat) -> CGFloat {
        measure.attributedStringValue = ConsoleFormat.message(message)
        let available = textWidth(width, indent: indent, link: ConsoleFormat.location(message) != nil, repeats: message.repeats)
        let size = measure.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: available, height: 100_000)) ?? .zero
        return max(ceil(size.height) + 6, 22)
    }

    func configure(_ message: ConsoleMessage, collapsed: Bool) {
        indent = CGFloat(message.depth) * 14
        let symbol: String?
        let color: NSColor
        switch (message.kind, message.level) {
        case (.command, _): (symbol, color) = ("chevron.right", .secondaryLabelColor)
        case (.result, .error): (symbol, color) = ("xmark.circle.fill", InspectorTheme.error)
        case (.result, _): (symbol, color) = ("arrow.left", .tertiaryLabelColor)
        case (_, .error): (symbol, color) = ("xmark.circle.fill", InspectorTheme.error)
        case (_, .warning): (symbol, color) = ("exclamationmark.triangle.fill", InspectorTheme.warning)
        case (.navigation, _): (symbol, color) = ("arrow.clockwise", InspectorTheme.link)
        default:
            (symbol, color) = message.isGroupStart ? (collapsed ? "chevron.right" : "chevron.down", .secondaryLabelColor) : (nil, .clear)
        }
        icon.image = symbol.flatMap { .symbol($0, size: 9.5, weight: .bold) }
        icon.contentTintColor = color
        let string = NSMutableAttributedString(attributedString: ConsoleFormat.message(message))
        if message.isGroupStart {
            string.addAttribute(.font, value: InspectorTheme.mono(11, .semibold), range: NSRange(location: 0, length: string.length))
        }
        text.attributedStringValue = string
        let location = ConsoleFormat.location(message)
        link.stringValue = location ?? ""
        link.isHidden = location == nil
        badge.isHidden = message.repeats < 2
        badge.stringValue = "\(message.repeats)"
        badge.textColor = .white
        badge.layer?.backgroundColor = (message.level == .error ? NSColor.systemRed : message.level == .warning ? NSColor.systemOrange
            : NSColor.systemGray).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = indent
        icon.frame = NSRect(x: x + 4, y: 4, width: 14, height: 14)
        var left = x + 22
        if !badge.isHidden {
            badge.frame = NSRect(x: left, y: 4, width: 20, height: 14)
            left += 24
        }
        let width = Self.textWidth(bounds.width, indent: indent, link: !link.isHidden, repeats: badge.isHidden ? 1 : 2)
        text.frame = NSRect(x: left, y: 3, width: width, height: bounds.height - 6)
        link.frame = NSRect(x: bounds.width - Self.linkWidth - 6, y: 4, width: Self.linkWidth, height: 14)
    }

    override var isFlipped: Bool { true }

    func linkHit(_ point: NSPoint) -> Bool {
        !link.isHidden && link.frame.insetBy(dx: -2, dy: -3).contains(point)
            && point.x >= link.frame.maxX - (link.attributedStringValue.size().width + 4)
    }
}

final class ConsolePrompt: FlippedView, NSTextViewDelegate {
    let textView = PromptTextView()
    private let scroll = NSScrollView()
    private let chevron = NSImageView()
    private let previewLabel = Label.make("", size: 11, color: .tertiaryLabelColor)
    private let line = CALayer()
    private let completions = CompletionList()
    weak var model: ConsoleModel?
    var onRun: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onResize: (() -> Void)?
    private var historyIndex: Int?
    private var draft = ""
    private var previewTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionPrefix = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        chevron.image = .symbol("chevron.right", size: 10, weight: .bold)
        chevron.contentTintColor = .controlAccentColor
        addSubview(chevron)
        textView.font = InspectorTheme.mono(11.5)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.lineFragmentPadding = 2
        textView.delegate = self
        textView.prompt = self
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        addSubview(previewLabel)
        completions.onPick = { [weak self] name in self?.accept(name) }
        completions.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        line.backgroundColor = InspectorTheme.separator.cgColor
    }

    var preferredHeight: CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 30 }
        layout.ensureLayout(for: container)
        let text = min(max(layout.usedRect(for: container).height + 10, 26), 140)
        return text + (previewLabel.stringValue.isEmpty ? 4 : 18)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
        chevron.frame = NSRect(x: 8, y: 7, width: 12, height: 14)
        let previewHeight: CGFloat = previewLabel.stringValue.isEmpty ? 0 : 16
        scroll.frame = NSRect(x: 22, y: 1, width: bounds.width - 28, height: bounds.height - 1 - previewHeight - 2)
        textView.frame.size.width = scroll.contentSize.width
        previewLabel.frame = NSRect(x: 24, y: bounds.height - previewHeight - 3, width: bounds.width - 32, height: previewHeight)
    }

    func textDidChange(_ notification: Notification) {
        historyIndex = nil
        onResize?()
        schedulePreview()
        scheduleCompletions()
    }

    fileprivate func handle(_ selector: Selector) -> Bool {
        let text = textView.string
        let caret = textView.selectedRange()
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { return false }
            if !completions.isHidden, completions.selected != nil, NSEvent.modifierFlags.isEmpty == false { return false }
            hideCompletions()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            if isIncomplete(text) { return false }
            textView.string = ""
            previewLabel.stringValue = ""
            historyIndex = nil
            onRun?(text)
            onResize?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if !completions.isHidden, let name = completions.selected { accept(name); return true }
            return false
        case #selector(NSResponder.moveRight(_:)):
            if !completions.isHidden, caret.location == (text as NSString).length, let name = completions.selected {
                accept(name)
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if !completions.isHidden { hideCompletions(); return true }
            return false
        case #selector(NSResponder.moveUp(_:)):
            if !completions.isHidden { completions.move(-1); return true }
            let firstLine = (text as NSString).substring(to: caret.location).contains("\n") == false
            guard firstLine else { return false }
            stepHistory(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            if !completions.isHidden { completions.move(1); return true }
            let lastLine = (text as NSString).substring(from: caret.location).contains("\n") == false
            guard lastLine, historyIndex != nil else { return false }
            stepHistory(1)
            return true
        default:
            return false
        }
    }

    private func isIncomplete(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for char in text {
            if let q = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == q { quote = nil }
                continue
            }
            switch char {
            case "\"", "'", "`": quote = char
            case "{", "(", "[": depth += 1
            case "}", ")", "]": depth -= 1
            default: break
            }
        }
        return depth > 0 || quote == "`"
    }

    private func stepHistory(_ step: Int) {
        let history = ConsoleModel.history
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            guard step < 0 else { return }
            draft = textView.string
            historyIndex = history.count
        }
        let next = historyIndex! + step
        if next >= history.count {
            historyIndex = nil
            textView.string = draft
        } else {
            historyIndex = max(next, 0)
            textView.string = history[historyIndex!]
        }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        onResize?()
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let text = textView.string
        guard let model, !text.isEmpty, text.count < 2000 else {
            setPreview("")
            return
        }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let result = await model.preview(text)
            guard !Task.isCancelled, let self, textView.string == text else { return }
            if let result, !(result.str("type") == "function" && !text.contains("(")), result.str("type") != "undefined" || text.contains("(") {
                setPreview(RemoteValue.summary(result).oneLine.clipped(300))
            } else {
                setPreview("")
            }
        }
    }

    private func setPreview(_ text: String) {
        guard previewLabel.stringValue != text else { return }
        let had = !previewLabel.stringValue.isEmpty
        previewLabel.stringValue = text
        if had != !text.isEmpty { onResize?() }
        needsLayout = true
    }

    private func scheduleCompletions() {
        completionTask?.cancel()
        let caret = textView.selectedRange().location
        let before = (textView.string as NSString).substring(to: min(caret, (textView.string as NSString).length))
        guard let model, let last = before.last, last.isLetter || last.isNumber || last == "_" || last == "$" || last == "." else {
            hideCompletions()
            return
        }
        completionTask = Task { [weak self] in
            let (prefix, names) = await model.completions(for: before)
            guard !Task.isCancelled, let self else { return }
            completionPrefix = prefix
            if names.isEmpty { hideCompletions() } else { showCompletions(names) }
        }
    }

    private func showCompletions(_ names: [String]) {
        guard let host = superview else { return }
        if completions.superview !== host { host.addSubview(completions, positioned: .above, relativeTo: nil) }
        completions.show(names)
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let local = window.map { host.convert($0.convertFromScreen(caret), from: nil) } ?? .zero
        let width: CGFloat = 240
        let height = min(CGFloat(names.count), 8) * 20 + 6
        completions.frame = NSRect(x: min(max(local.minX - 4, 4), host.bounds.width - width - 4),
                                   y: frame.minY - height - 2, width: width, height: height)
        completions.isHidden = false
    }

    private func hideCompletions() {
        completions.isHidden = true
    }

    private func accept(_ name: String) {
        let caret = textView.selectedRange().location
        let start = caret - (completionPrefix as NSString).length
        guard start >= 0 else { return }
        textView.insertText(name, replacementRange: NSRange(location: start, length: caret - start))
        hideCompletions()
        completionTask?.cancel()
    }

    override func removeFromSuperview() {
        completions.removeFromSuperview()
        super.removeFromSuperview()
    }
}

final class PromptTextView: NSTextView {
    fileprivate weak var prompt: ConsolePrompt?

    // swiftlint:disable:next prohibited_super_call
    override func doCommand(by selector: Selector) {
        if prompt?.handle(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k" {
            prompt?.onClear?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CompletionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var names: [String] = []
    var onPick: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(picked)
        table.action = #selector(picked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.cardFill.cgColor
        layer?.borderColor = InspectorTheme.separator.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 3)
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    func show(_ names: [String]) {
        self.names = names
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    var selected: String? {
        let row = table.selectedRow
        return names.indices.contains(row) ? names[row] : nil
    }

    func move(_ step: Int) {
        guard !names.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), names.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func picked() {
        if let selected { onPick?(selected) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        InspectorTable.cell(tableView, "completion", "  " + names[row], font: InspectorTheme.mono(11))
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }
}
