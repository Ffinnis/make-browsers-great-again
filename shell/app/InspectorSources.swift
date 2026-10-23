import AppKit

enum SourceKey: Hashable {
    case url(String)
    case script(String)
}

@MainActor
final class SourcesModel: InspectorModel {
    struct Script {
        let id: String
        let url: String
        let startLine: Int
        let startColumn: Int
        let frameID: String?
        let isDefault: Bool
        let hasSourceURL: Bool
        let order: Int

        var isInline: Bool { !hasSourceURL && (startLine > 0 || startColumn > 0) }
    }

    struct Sheet {
        let id: String
        let url: String
        let isInline: Bool
        let frameID: String?
        let order: Int
    }

    struct Breakpoint {
        var url: String
        var line: Int
        var column: Int?
        var condition = ""
        var enabled = true
        var id: String?
        var resolvedLine: Int?
    }

    struct Pause {
        let frames: [JSON]
        let reason: String
        let data: JSON?
        let hitBreakpoints: [String]
        let asyncTrace: JSON?
    }

    struct Content {
        var text = ""
        var language = CodeLanguage.plain
        var firstLine = 0
        var error: String?
    }

    private weak var session: InspectorSession?
    private(set) var scripts: [String: Script] = [:]
    private(set) var sheets: [String: Sheet] = [:]
    private(set) var breakpoints: [Breakpoint] = []
    private(set) var pause: Pause?
    var paused: Bool { pause != nil }
    var selectedFrame = 0
    var selectedCallFrameID: String? {
        guard let frames = pause?.frames, frames.indices.contains(selectedFrame) else { return nil }
        return frames[selectedFrame].str("callFrameId")
    }
    private(set) var pauseOnExceptions = "none"
    private(set) var breakpointsActive = true
    var lastOpened: (key: SourceKey, line: Int)?
    var prettyPrinted: Set<SourceKey> = []
    var keptPlain: Set<SourceKey> = []

    let sourcesChanged = Signal<Void>()
    let pauseChanged = Signal<Void>()
    let breakpointsChanged = Signal<Void>()

    private var contents: [SourceKey: Content] = [:]
    private var counter = 0

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session else { return }
        session.on("Debugger.", self) { [weak self] method, params in self?.debuggerEvent(method, params) }
        session.on("CSS.styleSheet", self) { [weak self] method, params in self?.sheetEvent(method, params) }
        session.call("Debugger.enable", ["maxScriptsCacheSize": 100_000_000])
        session.call("Debugger.setAsyncCallStackDepth", ["maxDepth": 32])
        session.call("DOM.enable") { _, _ in session.call("CSS.enable") }
        session.call("Overlay.enable")
    }

    func stop() {
        session?.call("Overlay.setPausedInDebuggerMessage")
        session?.call("Debugger.disable")
    }

    private func debuggerEvent(_ method: String, _ params: JSON) {
        switch method {
        case "Debugger.scriptParsed", "Debugger.scriptFailedToParse":
            guard let id = params.str("scriptId") else { return }
            counter += 1
            let aux = params.obj("executionContextAuxData")
            scripts[id] = Script(id: id, url: params.str("url") ?? "", startLine: params.int("startLine") ?? 0,
                                 startColumn: params.int("startColumn") ?? 0, frameID: aux?.str("frameId"),
                                 isDefault: aux?.bool("isDefault") ?? true, hasSourceURL: params.bool("hasSourceURL"),
                                 order: counter)
            sourcesChanged.send()
        case "Debugger.paused":
            pause = Pause(frames: params.list("callFrames"), reason: params.str("reason") ?? "other",
                          data: params.obj("data"), hitBreakpoints: params["hitBreakpoints"] as? [String] ?? [],
                          asyncTrace: params.obj("asyncStackTrace"))
            selectedFrame = 0
            session?.call("Overlay.setPausedInDebuggerMessage", ["message": "Paused in MBGA"])
            session?.showPanel?(.sources)
            pauseChanged.send()
        case "Debugger.resumed":
            guard pause != nil else { return }
            pause = nil
            session?.call("Overlay.setPausedInDebuggerMessage")
            pauseChanged.send()
        case "Debugger.breakpointResolved":
            guard let id = params.str("breakpointId"), let index = breakpoints.firstIndex(where: { $0.id == id }) else { return }
            breakpoints[index].resolvedLine = params.obj("location")?.int("lineNumber")
            breakpointsChanged.send()
        case "Debugger.globalObjectCleared":
            scripts = [:]
            contents = [:]
            if pause != nil {
                pause = nil
                pauseChanged.send()
            }
            sourcesChanged.send()
        default:
            break
        }
    }

    private func sheetEvent(_ method: String, _ params: JSON) {
        switch method {
        case "CSS.styleSheetAdded":
            guard let header = params.obj("header"), let id = header.str("styleSheetId"),
                  header.str("origin") == "regular" else { return }
            counter += 1
            sheets[id] = Sheet(id: id, url: header.str("sourceURL") ?? "", isInline: header.bool("isInline"),
                               frameID: header.str("frameId"), order: counter)
            sourcesChanged.send()
        case "CSS.styleSheetRemoved":
            guard let id = params.str("styleSheetId"), sheets.removeValue(forKey: id) != nil else { return }
            sourcesChanged.send()
        case "CSS.styleSheetChanged":
            if let id = params.str("styleSheetId"), let url = sheets[id]?.url { contents[.url(url)] = nil }
        default:
            break
        }
    }

    var fileURLs: [String] {
        var urls = Set<String>()
        if let page = session?.url, !page.isEmpty, !page.hasPrefix("about:") { urls.insert(page) }
        for script in scripts.values where script.isDefault && Self.listable(script.url) { urls.insert(script.url) }
        for sheet in sheets.values where Self.listable(sheet.url) { urls.insert(sheet.url) }
        return urls.sorted()
    }

    private static func listable(_ url: String) -> Bool {
        !url.isEmpty && !["chrome-extension:", "chrome:", "devtools:", "extensions::", "debugger:", "about:"].contains { url.hasPrefix($0) }
    }

    func language(of key: SourceKey) -> CodeLanguage {
        guard case .url(let url) = key else { return .javascript }
        if latestScript(url: url) != nil { return .javascript }
        if latestSheet(url: url) != nil { return .css }
        if url == session?.url || scripts.values.contains(where: { $0.url == url && $0.isInline }) { return .html }
        let guess = CodeLanguage.guess(mime: "", url: url)
        return guess == .plain && url.hasSuffix("/") ? .html : guess
    }

    func key(forScript id: String) -> SourceKey {
        guard let script = scripts[id], !script.url.isEmpty else { return .script(id) }
        return .url(script.url)
    }

    private func latestScript(url: String) -> Script? {
        scripts.values.filter { $0.url == url && !$0.isInline }.max { $0.order < $1.order }
    }

    private func latestSheet(url: String) -> Sheet? {
        sheets.values.filter { $0.url == url && !$0.isInline }.max { $0.order < $1.order }
    }

    func content(_ key: SourceKey) async -> Content {
        if let cached = contents[key] { return cached }
        guard let session else { return Content(error: "The page is closed.") }
        var result: Content
        switch key {
        case .script(let id):
            guard let script = scripts[id] else { return Content(error: "The script is gone; the page reloaded.") }
            result = await scriptContent(script, session)
        case .url(let url):
            if let script = latestScript(url: url) {
                result = await scriptContent(script, session)
            } else if let sheet = latestSheet(url: url) {
                do {
                    let text = try await session.send("CSS.getStyleSheetText", ["styleSheetId": sheet.id]).str("text") ?? ""
                    result = Content(text: text, language: .css)
                } catch {
                    result = Content(error: "\(error)")
                }
            } else {
                result = await resourceContent(url, session)
            }
        }
        if result.error == nil { contents[key] = result }
        return result
    }

    private func scriptContent(_ script: Script, _ session: InspectorSession) async -> Content {
        do {
            let source = try await session.send("Debugger.getScriptSource", ["scriptId": script.id])
            if source["bytecode"] != nil, source.str("scriptSource")?.isEmpty != false {
                return Content(error: "WebAssembly modules aren't shown here.")
            }
            return Content(text: source.str("scriptSource") ?? "", language: .javascript,
                           firstLine: script.url.isEmpty || !script.isInline ? script.startLine : 0)
        } catch {
            return Content(error: "\(error)")
        }
    }

    private func resourceContent(_ url: String, _ session: InspectorSession) async -> Content {
        let inline = scripts.values.filter { $0.url == url && $0.isInline }.sorted { $0.startLine < $1.startLine }
        let frame = inline.first?.frameID ?? sheets.values.first { $0.url == url }?.frameID ?? session.mainFrameID
        let language = language(of: .url(url))
        do {
            let resource = try await session.send("Page.getResourceContent", ["frameId": frame, "url": url])
            var text = resource.str("content") ?? ""
            if resource.bool("base64Encoded") {
                guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else {
                    return Content(error: "This file isn't text.")
                }
                text = decoded
            }
            return Content(text: text, language: language)
        } catch {
            guard !inline.isEmpty else { return Content(error: "\(error)") }
            var lines: [String] = []
            for script in inline {
                guard let source = try? await session.send("Debugger.getScriptSource", ["scriptId": script.id]).str("scriptSource") else { continue }
                while lines.count < script.startLine { lines.append("") }
                let scriptLines = source.components(separatedBy: "\n")
                for (i, line) in scriptLines.enumerated() {
                    let index = script.startLine + i
                    let text = i == 0 ? String(repeating: " ", count: script.startColumn) + line : line
                    if index < lines.count { lines[index] += text } else { lines.append(text) }
                }
            }
            return Content(text: lines.joined(separator: "\n"), language: .javascript)
        }
    }

    func cachedLine(_ url: String, _ line: Int) -> String? {
        guard let content = contents[.url(url)] else { return nil }
        let index = line - content.firstLine
        let lines = content.text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.indices.contains(index) ? lines[index].trimmingCharacters(in: .whitespaces) : nil
    }

    func toggleBreakpoint(url: String, line: Int, column: Int? = nil) {
        if let index = breakpoints.firstIndex(where: { $0.url == url && ($0.line == line || $0.resolvedLine == line) }) {
            remove(at: index)
        } else {
            add(Breakpoint(url: url, line: line, column: column))
        }
    }

    func add(_ breakpoint: Breakpoint) {
        breakpoints.append(breakpoint)
        breakpointsChanged.send()
        install(breakpoints.count - 1)
    }

    private func install(_ index: Int) {
        guard let session, breakpoints.indices.contains(index) else { return }
        let breakpoint = breakpoints[index]
        var params: JSON = ["url": breakpoint.url, "lineNumber": breakpoint.line, "condition": breakpoint.condition]
        if let column = breakpoint.column { params["columnNumber"] = column }
        session.call("Debugger.setBreakpointByUrl", params) { [weak self] result, _ in
            guard let self, let id = result?.str("breakpointId"),
                  let index = breakpoints.firstIndex(where: { $0.url == breakpoint.url && $0.line == breakpoint.line && $0.id == nil })
            else { return }
            breakpoints[index].id = id
            breakpoints[index].resolvedLine = result?.list("locations").first?.int("lineNumber")
            breakpointsChanged.send()
        }
    }

    private func uninstall(_ index: Int) {
        guard let id = breakpoints[index].id else { return }
        breakpoints[index].id = nil
        session?.call("Debugger.removeBreakpoint", ["breakpointId": id])
    }

    func remove(at index: Int) {
        guard breakpoints.indices.contains(index) else { return }
        uninstall(index)
        breakpoints.remove(at: index)
        breakpointsChanged.send()
    }

    func removeAll() {
        for index in breakpoints.indices { uninstall(index) }
        breakpoints = []
        breakpointsChanged.send()
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard breakpoints.indices.contains(index), breakpoints[index].enabled != enabled else { return }
        breakpoints[index].enabled = enabled
        if enabled { install(index) } else { uninstall(index) }
        breakpointsChanged.send()
    }

    func setCondition(_ condition: String, at index: Int) {
        guard breakpoints.indices.contains(index) else { return }
        uninstall(index)
        breakpoints[index].condition = condition
        if breakpoints[index].enabled { install(index) }
        breakpointsChanged.send()
    }

    func resume() { session?.call("Debugger.resume") }
    func pauseNow() { session?.call("Debugger.pause") }
    func stepOver() { session?.call("Debugger.stepOver") }
    func stepInto() { session?.call("Debugger.stepInto") }
    func stepOut() { session?.call("Debugger.stepOut") }

    func continueTo(scriptID: String, line: Int, column: Int) {
        session?.call("Debugger.continueToLocation", ["location": ["scriptId": scriptID, "lineNumber": line, "columnNumber": column]])
    }

    func setPauseOnExceptions(_ state: String) {
        pauseOnExceptions = state
        session?.call("Debugger.setPauseOnExceptions", ["state": state])
        pauseChanged.send()
    }

    func setBreakpointsActive(_ active: Bool) {
        breakpointsActive = active
        session?.call("Debugger.setBreakpointsActive", ["active": active])
        breakpointsChanged.send()
    }

    func selectFrame(_ index: Int) {
        guard let frames = pause?.frames, frames.indices.contains(index) else { return }
        selectedFrame = index
        pauseChanged.send()
    }

    func scriptID(at key: SourceKey, line: Int) -> String? {
        switch key {
        case .script(let id): return id
        case .url(let url):
            let candidates = scripts.values.filter { $0.url == url }
            return (candidates.filter { $0.startLine <= line }.max { $0.startLine < $1.startLine } ?? candidates.first)?.id
        }
    }
}

private struct PrettyText {
    let text: String
    let starts: [(line: Int, column: Int)]

    func line(forOriginal line: Int, column: Int) -> Int {
        var low = 0, high = starts.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            let start = starts[mid]
            if start.line < line || (start.line == line && start.column <= column) {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

private enum PrettyPrinter {
    private enum Kind { case word, string, comment, lineComment, punct }
    private struct Token {
        let kind: Kind
        let start: Int
        let end: Int
        let newlineBefore: Bool
    }

    private static let keywordsBeforeExpression: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
        "yield", "await",
    ]
    private static let spacedKeywords: Set<String> = keywordsBeforeExpression.union([
        "if", "for", "while", "switch", "catch", "const", "let", "var", "function", "async", "export", "import",
        "from", "as", "extends", "class", "try", "finally", "static", "get", "set",
    ])
    private static let operators = [">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=", "=>",
                                    "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=",
                                    "%=", "&=", "|=", "^=", "**", "<<", ">>"].map { Array($0.utf16) }
    private static let spacedOperators: Set<String> = [
        "=", "==", "===", "!=", "!==", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "&&", "||", "??", "?", ":",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**=", "<<=", ">>=", ">>>=", "&&=", "||=", "??=", "=>",
        "&", "|", "^", "**", "<<", ">>", ">>>", "instanceof",
    ]

    static func isMinified(_ text: String) -> Bool {
        let lines = max(text.utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }, 1)
        return text.utf16.count / lines > 300
    }

    static func format(_ source: String, css: Bool) -> PrettyText {
        let units = Array(source.utf16)
        var lineStarts = [0]
        for (i, unit) in units.enumerated() where unit == 10 { lineStarts.append(i + 1) }
        func location(_ offset: Int) -> (line: Int, column: Int) {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return (low, offset - lineStarts[low])
        }
        let tokens = css ? cssTokens(units) : jsTokens(units)
        func text(_ token: Token) -> String { String(decoding: units[token.start..<token.end], as: UTF16.self) }

        var out = ""
        out.reserveCapacity(units.count + units.count / 4)
        var starts: [(line: Int, column: Int)] = []
        var indent = 0
        var atLineStart = true
        var pendingSpace = false

        func newline() {
            if !atLineStart {
                out += "\n"
                atLineStart = true
            }
            pendingSpace = false
        }
        func emit(_ string: String, at offset: Int, space: Bool) {
            if atLineStart {
                out += String(repeating: "  ", count: max(indent, 0))
                starts.append(location(offset))
                atLineStart = false
            } else if space || pendingSpace {
                out += " "
            }
            pendingSpace = false
            out += string
        }

        if css {
            for (i, token) in tokens.enumerated() {
                let string = text(token)
                switch string {
                case "{":
                    emit("{", at: token.start, space: true)
                    indent += 1
                    newline()
                case "}":
                    indent -= 1
                    newline()
                    emit("}", at: token.start, space: false)
                    newline()
                case ";":
                    emit(";", at: token.start, space: false)
                    newline()
                default:
                    if token.kind == .comment {
                        newline()
                        emit(string, at: token.start, space: false)
                        newline()
                    } else {
                        let collapsed = string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        emit(collapsed, at: token.start, space: i > 0 && !atLineStart)
                    }
                }
            }
            return PrettyText(text: out, starts: starts.isEmpty ? [(0, 0)] : starts)
        }

        var braces: [(object: Bool, depth: Int)] = []
        var depth = 0
        var previous: (kind: Kind, text: String)?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let string = text(token)
            let next = i + 1 < tokens.count ? text(tokens[i + 1]) : nil
            let wordLike = token.kind == .word || token.kind == .string
            let prevWordLike = previous.map { $0.kind == .word || $0.kind == .string || [")", "]"].contains($0.text) } ?? false
            if token.newlineBefore, wordLike, prevWordLike, depth == (braces.last?.depth ?? 0) { newline() }
            var space = false
            if let previous {
                if previous.kind == .word || previous.kind == .string, wordLike { space = true }
                if previous.kind == .word, spacedKeywords.contains(previous.text),
                   ![";", ",", ".", ")", "]", "?."].contains(string), !(previous.text == "function" && string == "(") {
                    space = true
                }
            }
            switch token.kind {
            case .lineComment:
                emit(string, at: token.start, space: !atLineStart)
                newline()
            case .comment:
                if token.newlineBefore { newline() }
                emit(string, at: token.start, space: true)
                if token.newlineBefore { newline() }
            case .punct:
                switch string {
                case "{":
                    let object: Bool = {
                        guard let previous else { return false }
                        if previous.kind == .word { return keywordsBeforeExpression.contains(previous.text) && previous.text != "else" && previous.text != "do" }
                        return previous.kind == .punct && ![")", "=>", "]", "}", ";"].contains(previous.text)
                    }()
                    if next == "}" {
                        emit("{}", at: token.start, space: true)
                        i += 2
                        previous = (.punct, "}")
                        continue
                    }
                    emit("{", at: token.start, space: true)
                    braces.append((object, depth))
                    indent += 1
                    newline()
                case "}":
                    indent -= 1
                    if let open = braces.popLast() { depth = open.depth }
                    newline()
                    emit("}", at: token.start, space: false)
                    if let next, [")", "]", ",", ";", ".", "?."].contains(next) {
                    } else if let next, ["else", "catch", "finally"].contains(next) {
                        pendingSpace = true
                    } else {
                        newline()
                    }
                case ";":
                    emit(";", at: token.start, space: false)
                    if depth > (braces.last?.depth ?? 0) { pendingSpace = true } else if next != "}" { newline() }
                case ",":
                    emit(",", at: token.start, space: false)
                    if let top = braces.last, top.object, depth == top.depth { newline() } else { pendingSpace = true }
                case "(", "[":
                    emit(string, at: token.start, space: space || (previous?.kind == .word && spacedKeywords.contains(previous?.text ?? "") && previous?.text != "function"))
                    depth += 1
                case ")", "]":
                    depth -= 1
                    emit(string, at: token.start, space: false)
                case "!", "~":
                    emit(string, at: token.start, space: space)
                default:
                    let unary = (string == "+" || string == "-") && (previous == nil || (previous!.kind == .punct && ![")", "]", "}"].contains(previous!.text))
                        || (previous!.kind == .word && keywordsBeforeExpression.contains(previous!.text)))
                    if spacedOperators.contains(string), !unary {
                        emit(string, at: token.start, space: string != ":")
                        pendingSpace = true
                    } else {
                        emit(string, at: token.start, space: space)
                    }
                }
            case .word, .string:
                emit(string, at: token.start, space: space)
            }
            previous = (token.kind, string)
            i += 1
        }
        return PrettyText(text: out, starts: starts.isEmpty ? [(0, 0)] : starts)
    }

    private static func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 || c == 0xFEFF }

    private static func jsTokens(_ u: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0, sawNewline = false
        let n = u.count
        func regexAllowed() -> Bool {
            guard let last = tokens.last(where: { $0.kind != .comment && $0.kind != .lineComment }) else { return true }
            if last.kind == .punct {
                let c = u[last.start]
                return !(last.end - last.start == 1 && (c == 41 || c == 93))
            }
            if last.kind == .word {
                return keywordsBeforeExpression.contains(String(decoding: u[last.start..<last.end], as: UTF16.self))
            }
            return false
        }
        while i < n {
            let c = u[i]
            if isSpace(c) {
                if c == 10 { sawNewline = true }
                i += 1
                continue
            }
            let start = i
            var kind = Kind.punct
            if c == 47, i + 1 < n, u[i + 1] == 47 {
                while i < n, u[i] != 10 { i += 1 }
                kind = .lineComment
            } else if c == 47, i + 1 < n, u[i + 1] == 42 {
                i += 2
                while i + 1 < n, !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                i = min(i + 2, n)
                kind = .comment
            } else if c == 34 || c == 39 {
                i += 1
                while i < n, u[i] != c, u[i] != 10 { i += u[i] == 92 ? 2 : 1 }
                i = min(i + 1, n)
                kind = .string
            } else if c == 96 {
                i += 1
                var nesting = 0
                while i < n {
                    if u[i] == 92 { i += 2; continue }
                    if nesting == 0, u[i] == 96 { break }
                    if u[i] == 36, i + 1 < n, u[i + 1] == 123 { nesting += 1; i += 2; continue }
                    if nesting > 0, u[i] == 125 { nesting -= 1 }
                    i += 1
                }
                i = min(i + 1, n)
                kind = .string
            } else if c == 47, regexAllowed() {
                i += 1
                var inClass = false
                while i < n, u[i] != 10 {
                    if u[i] == 92 { i += 2; continue }
                    if u[i] == 91 { inClass = true } else if u[i] == 93 { inClass = false } else if u[i] == 47, !inClass { break }
                    i += 1
                }
                i = min(i + 1, n)
                while i < n, isIdentifier(u[i]) { i += 1 }
                kind = .string
            } else if isIdentifier(c) {
                let number = c >= 48 && c <= 57
                while i < n, isIdentifier(u[i]) || (number && (u[i] == 46 || ((u[i] == 43 || u[i] == 45) && (u[i - 1] == 101 || u[i - 1] == 69)))) {
                    i += 1
                }
                kind = .word
            } else if c == 46, i + 1 < n, u[i + 1] >= 48, u[i + 1] <= 57 {
                i += 1
                while i < n, isIdentifier(u[i]) { i += 1 }
                kind = .word
            } else {
                var matched = 1
                for op in operators where i + op.count <= n && Array(u[i..<(i + op.count)]) == op {
                    matched = op.count
                    break
                }
                i += matched
            }
            tokens.append(Token(kind: kind, start: start, end: i, newlineBefore: sawNewline))
            sawNewline = false
        }
        return tokens
    }

    private static func cssTokens(_ u: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = u.count
        while i < n {
            let c = u[i]
            if isSpace(c) { i += 1; continue }
            let start = i
            if c == 47, i + 1 < n, u[i + 1] == 42 {
                i += 2
                while i + 1 < n, !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                i = min(i + 2, n)
                tokens.append(Token(kind: .comment, start: start, end: i, newlineBefore: false))
            } else if c == 123 || c == 125 || c == 59 {
                i += 1
                tokens.append(Token(kind: .punct, start: start, end: i, newlineBefore: false))
            } else {
                var parens = 0
                while i < n {
                    let d = u[i]
                    if d == 34 || d == 39 {
                        i += 1
                        while i < n, u[i] != d { i += u[i] == 92 ? 2 : 1 }
                        i = min(i + 1, n)
                        continue
                    }
                    if d == 40 { parens += 1 } else if d == 41 { parens = max(parens - 1, 0) }
                    if parens == 0, d == 123 || d == 125 || d == 59 { break }
                    if d == 47, i + 1 < n, u[i + 1] == 42 { break }
                    i += 1
                }
                var end = i
                while end > start, isSpace(u[end - 1]) { end -= 1 }
                tokens.append(Token(kind: .word, start: start, end: end, newlineBefore: false))
            }
        }
        return tokens
    }
}

final class SourcesPanel: InspectorPanelView, NSTextViewDelegate {
    private var model: SourcesModel?
    private let toolbar = InspectorToolbar()
    private let navigatorToggle = InspectorButton("sidebar.left", tip: "Show or hide the file list")
    private let title = SourceTitleView()
    private let pretty = InspectorButton("curlybraces", tip: "Pretty-print")
    private let pauseButton = InspectorButton("pause.fill", tip: "Pause script execution  ⌘\\  F8")
    private let stepOverButton = InspectorButton("arrow.uturn.right", tip: "Step over  ⌘'  F10")
    private let stepIntoButton = InspectorButton("arrow.down.to.line", tip: "Step into  ⌘;  F11")
    private let stepOutButton = InspectorButton("arrow.up.to.line", tip: "Step out  ⇧⌘;  ⇧F11")
    private let deactivate = InspectorButton("bookmark.slash", tip: "Deactivate breakpoints")
    private let exceptions = InspectorButton("exclamationmark.octagon", tip: "Pause on exceptions")

    private let navigatorPane = FlippedView()
    private let filter = InspectorFilterField(placeholder: "Filter files")
    private let navigator = InspectorOutlineView()
    private lazy var navigatorScroll = Self.scroll(navigator)
    private let navigatorSource = NavigatorSource()

    private let codePane = FlippedView()
    private let code = CodeView()
    private let codeEmpty = InspectorEmptyView("Choose a file to see its source.")
    private let debuggerPane = FlippedView()
    private let banner = PausedBanner()
    private let debugger = InspectorOutlineView()
    private lazy var debuggerScroll = Self.scroll(debugger)
    private let debuggerSource = DebuggerSource()

    private lazy var codeSplit = InspectorSplitView(codePane, debuggerPane, vertical: false, key: "sources.debugger",
                                                    fraction: 0.6, minimum: 70)
    private lazy var split = InspectorSplitView(navigatorPane, codeSplit, vertical: true, key: "sources.navigator",
                                                fraction: 0.3, minimum: 120)

    private var openKey: SourceKey?
    private var loadedKey: SourceKey?
    private var content = SourcesModel.Content()
    private var prettyText: PrettyText?
    private var openToken = 0
    private var history: [SourceKey] = []
    private lazy var navigatorReload = Coalescer(delay: 0.2) { [weak self] in self?.reloadNavigator() }
    private static let navigatorKey = "inspector.sources.navigator"
    private var navigatorChoice: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
        addSubview(split)
        toolbar.add(navigatorToggle, width: 24)
        toolbar.add(title, width: nil)
        toolbar.add(pretty, width: 24)
        toolbar.addSeparator()
        for button in [pauseButton, stepOverButton, stepIntoButton, stepOutButton] { toolbar.add(button, width: 24) }
        toolbar.addSeparator()
        toolbar.add(deactivate, width: 24)
        toolbar.add(exceptions, width: 24)
        navigatorToggle.action = { [weak self] in self?.toggleNavigator() }
        title.onClick = { [weak self] in self?.showHistory() }
        pretty.action = { [weak self] in self?.togglePretty() }
        pauseButton.action = { [weak self] in self?.togglePause() }
        stepOverButton.action = { [weak self] in self?.model?.stepOver() }
        stepIntoButton.action = { [weak self] in self?.model?.stepInto() }
        stepOutButton.action = { [weak self] in self?.model?.stepOut() }
        deactivate.action = { [weak self] in
            guard let model = self?.model else { return }
            model.setBreakpointsActive(!model.breakpointsActive)
        }
        exceptions.onColor = InspectorTheme.warning
        exceptions.action = { [weak self] in self?.showExceptionsMenu() }

        navigatorPane.addSubview(filter)
        navigatorPane.addSubview(navigatorScroll)
        filter.onChange = { [weak self] _ in self?.reloadNavigator() }
        Self.setUpOutline(navigator)
        navigator.indentationPerLevel = 10
        navigator.dataSource = navigatorSource
        navigator.delegate = navigatorSource
        navigatorSource.onOpen = { [weak self] url in
            self?.open(.url(url))
            if self?.navigatorAutoHides == true {
                self?.navigatorChoice = nil
                self?.setNavigatorShown(false, remember: false)
            }
        }

        codePane.addSubview(code)
        codePane.addSubview(codeEmpty)
        code.textView.delegate = self
        code.onGutterClick = { [weak self] line in self?.gutterClicked(line) }

        debuggerPane.addSubview(banner)
        debuggerPane.addSubview(debuggerScroll)
        banner.isHidden = true
        Self.setUpOutline(debugger)
        debugger.indentationPerLevel = 12
        debugger.dataSource = debuggerSource
        debugger.delegate = debuggerSource
        debugger.target = debuggerSource
        debugger.action = #selector(DebuggerSource.clicked(_:))
        debugger.menuForRow = { [weak self] row in self?.debuggerSource.menu(row) }
        debuggerSource.outline = debugger
        debuggerSource.panel = self
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func scroll(_ outline: NSOutlineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    private static func setUpOutline(_ outline: NSOutlineView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 19
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        split.frame = NSRect(x: 0, y: InspectorToolbar.height, width: bounds.width,
                             height: max(bounds.height - InspectorToolbar.height, 0))
        split.layoutSubtreeIfNeeded()
        filter.frame = NSRect(x: 6, y: 5, width: max(navigatorPane.bounds.width - 12, 0), height: 22)
        navigatorScroll.frame = NSRect(x: 0, y: 32, width: navigatorPane.bounds.width, height: max(navigatorPane.bounds.height - 32, 0))
        code.frame = codePane.bounds
        codeEmpty.frame = codePane.bounds
        let bannerHeight: CGFloat = banner.isHidden ? 0 : banner.height(for: debuggerPane.bounds.width)
        banner.frame = NSRect(x: 0, y: 0, width: debuggerPane.bounds.width, height: bannerHeight)
        debuggerScroll.frame = NSRect(x: 0, y: bannerHeight, width: debuggerPane.bounds.width,
                                      height: max(debuggerPane.bounds.height - bannerHeight, 0))
        for view in [navigatorScroll, code, codeEmpty, debuggerScroll] as [NSView] { view.autoresizingMask = [.width, .height] }
        filter.autoresizingMask = [.width]
        banner.autoresizingMask = [.width]
        debugger.sizeLastColumnToFit()
        navigator.sizeLastColumnToFit()
        applyNavigatorVisibility()
    }

    override func sessionChanged() {
        detachModel()
        clearFile()
        if isShown { attachModel() }
    }

    override func panelDidAppear() {
        attachModel()
        takePendingSource()
    }

    private func attachModel() {
        guard let session, model == nil else { return }
        let model = session.model(SourcesModel.self)
        self.model = model
        debuggerSource.model = model
        debuggerSource.session = session
        model.sourcesChanged.observe(self) { [weak self] in self?.navigatorReload.schedule() }
        model.breakpointsChanged.observe(self) { [weak self] in
            self?.updateMarks()
            self?.debuggerSource.reload()
            self?.updateControls()
        }
        model.pauseChanged.observe(self) { [weak self] in self?.pauseChanged() }
        session.sourceRequested.observe(self) { [weak self] in
            guard let self, isShown else { return }
            takePendingSource()
        }
        session.navigated.observe(self) { [weak self] _ in self?.navigatorReload.schedule() }
        reloadNavigator()
        debuggerSource.reload()
        updateControls()
        if model.paused {
            pauseChanged()
        } else if let last = model.lastOpened {
            open(last.key, line: last.line)
        }
    }

    private func detachModel() {
        if let model {
            model.sourcesChanged.stopObserving(self)
            model.breakpointsChanged.stopObserving(self)
            model.pauseChanged.stopObserving(self)
        }
        model = nil
        debuggerSource.model = nil
        debuggerSource.session = nil
        debuggerSource.reload()
        navigatorSource.roots = []
        navigator.reloadData()
        updateControls()
    }

    private func takePendingSource() {
        guard let request = session?.takePendingSource() else { return }
        open(.url(request.url), line: request.line, column: request.column, select: true)
    }

    private var navigatorShownState: Bool? {
        UserDefaults.standard.object(forKey: Self.navigatorKey) as? Bool
    }

    private var navigatorAutoHides: Bool { bounds.width < 560 }

    private func applyNavigatorVisibility() {
        guard bounds.width > 0 else { return }
        let shown = navigatorChoice ?? (navigatorAutoHides ? false : navigatorShownState ?? true)
        if navigatorPane.isHidden == shown { setNavigatorShown(shown, remember: false) }
    }

    private func toggleNavigator() {
        setNavigatorShown(navigatorPane.isHidden)
    }

    private func setNavigatorShown(_ shown: Bool, remember: Bool = true) {
        if remember {
            if navigatorAutoHides { navigatorChoice = shown } else {
                navigatorChoice = nil
                UserDefaults.standard.set(shown, forKey: Self.navigatorKey)
            }
        }
        navigatorPane.isHidden = !shown
        split.adjustSubviews()
        if shown {
            split.setPosition(min(max(split.bounds.width * 0.3, 140), 260), ofDividerAt: 0)
        }
        navigatorToggle.isOn = shown
        needsLayout = true
    }

    private func reloadNavigator() {
        guard let model else { return }
        let urls = model.fileURLs
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let pageHost = URLComponents(string: session?.url ?? "")?.host
        navigatorSource.build(urls: urls, query: query, pageHost: pageHost, language: { model.language(of: .url($0)) })
        navigator.reloadData()
        if query.isEmpty {
            for root in navigatorSource.roots where root.isPage || navigatorSource.roots.count == 1 {
                expandDown(root)
            }
        }
        if case .url(let url) = openKey { selectInNavigator(url) }
    }

    private func expandDown(_ node: SourceTreeNode) {
        navigator.expandItem(node)
        if node.children.count == 1, let only = node.children.first, only.url == nil { expandDown(only) }
    }

    private func selectInNavigator(_ url: String) {
        guard let node = navigatorSource.node(for: url) else { return }
        var chain: [SourceTreeNode] = []
        var parent = node.parent
        while let p = parent { chain.insert(p, at: 0); parent = p.parent }
        for p in chain { navigator.expandItem(p) }
        let row = navigator.row(forItem: node)
        guard row >= 0 else { return }
        navigatorSource.ignoringSelection = true
        navigator.selectRowIndexes([row], byExtendingSelection: false)
        navigatorSource.ignoringSelection = false
        navigator.scrollRowToVisible(row)
    }

    private func clearFile() {
        openKey = nil
        loadedKey = nil
        content = SourcesModel.Content()
        prettyText = nil
        code.show("", language: .plain)
        code.markedLines = []
        code.highlightedLine = nil
        codeEmpty.isHidden = false
        codeEmpty.text = "Choose a file to see its source."
        title.set(nil, detail: nil)
        updateControls()
    }

    func open(_ key: SourceKey, line: Int? = nil, column: Int = 0, select: Bool = false) {
        guard let model else { return }
        if openKey == key, loadedKey == key {
            if let line { reveal(line: line, column: column, select: select) }
            updateHighlight()
            return
        }
        openToken += 1
        let token = openToken
        openKey = key
        history.removeAll { $0 == key }
        history.insert(key, at: 0)
        if history.count > 20 { history.removeLast() }
        title.set(displayName(key), detail: displayDetail(key))
        codeEmpty.text = "Loading…"
        codeEmpty.isHidden = false
        Task { [weak self] in
            let content = await model.content(key)
            guard let self, token == openToken else { return }
            show(content, for: key)
            if let line { reveal(line: line, column: column, select: select) }
            model.lastOpened = (key, line ?? 0)
        }
        if case .url(let url) = key { selectInNavigator(url) }
    }

    private func show(_ content: SourcesModel.Content, for key: SourceKey) {
        guard let model else { return }
        self.content = content
        loadedKey = key
        if let error = content.error {
            codeEmpty.text = error
            codeEmpty.isHidden = false
            code.show("", language: .plain)
            prettyText = nil
            updateControls()
            return
        }
        codeEmpty.isHidden = true
        let formattable = content.language == .javascript || content.language == .css
        if formattable, !model.keptPlain.contains(key), !model.prettyPrinted.contains(key), PrettyPrinter.isMinified(content.text) {
            model.prettyPrinted.insert(key)
        }
        if formattable, model.prettyPrinted.contains(key) {
            prettyText = PrettyPrinter.format(content.text, css: content.language == .css)
            code.firstLineNumber = 1
            code.show(prettyText!.text, language: content.language)
        } else {
            prettyText = nil
            code.firstLineNumber = content.firstLine + 1
            code.show(content.text, language: content.language)
        }
        updateMarks()
        updateHighlight()
        updateControls()
    }

    private func togglePretty() {
        guard let model, let key = openKey else { return }
        let topLine = originalLocation(forDisplayLine: visibleTopLine()).line
        if model.prettyPrinted.contains(key) {
            model.prettyPrinted.remove(key)
            model.keptPlain.insert(key)
        } else {
            model.prettyPrinted.insert(key)
            model.keptPlain.remove(key)
        }
        show(content, for: key)
        code.reveal(line: displayLine(forOriginal: topLine, column: 0))
    }

    private func visibleTopLine() -> Int {
        guard let layout = code.textView.layoutManager, let container = code.textView.textContainer else { return 0 }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: code.contentView.bounds.minY), in: container)
        return Self.line(at: layout.characterIndexForGlyph(at: glyph), in: code.textView.string)
    }

    private static func line(at offset: Int, in text: String) -> Int {
        text.utf16.prefix(offset).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    private func displayLine(forOriginal line: Int, column: Int) -> Int {
        if let prettyText { return prettyText.line(forOriginal: line, column: column) }
        return line - content.firstLine
    }

    private func originalLocation(forDisplayLine line: Int) -> (line: Int, column: Int?) {
        if let prettyText, prettyText.starts.indices.contains(line) {
            let start = prettyText.starts[line]
            return (start.line, start.column)
        }
        return (line + content.firstLine, nil)
    }

    private func reveal(line: Int, column: Int, select: Bool) {
        code.reveal(line: displayLine(forOriginal: line, column: column), select: select)
    }

    private func displayName(_ key: SourceKey) -> String {
        switch key {
        case .script(let id): return "VM\(id)"
        case .url(let url):
            guard let parts = URLComponents(string: url) else { return url }
            let name = (parts.path as NSString).lastPathComponent
            let file = name.isEmpty || name == "/" ? "(index)" : name
            return parts.query.map { "\(file)?\($0)" } ?? file
        }
    }

    private func displayDetail(_ key: SourceKey) -> String? {
        guard case .url(let url) = key, let parts = URLComponents(string: url) else { return nil }
        return parts.host.map { host in parts.port.map { "\(host):\($0)" } ?? host }
    }

    private func showHistory() {
        guard history.count > 1 else { return }
        let menu = NSMenu()
        for key in history.dropFirst() {
            menu.add(displayName(key) + (displayDetail(key).map { " — \($0)" } ?? "")) { [weak self] in self?.open(key) }
        }
        title.popUp(menu)
    }

    private var openURL: String? {
        if case .url(let url) = openKey { return url }
        return nil
    }

    private func gutterClicked(_ line: Int) {
        guard let model, let url = openURL, content.error == nil else { return }
        let location = originalLocation(forDisplayLine: line)
        if let existing = model.breakpoints.firstIndex(where: { breakpoint in
            breakpoint.url == url && displayLine(forOriginal: breakpoint.resolvedLine ?? breakpoint.line, column: breakpoint.column ?? 0) == line
        }) {
            model.remove(at: existing)
        } else {
            model.add(SourcesModel.Breakpoint(url: url, line: location.line, column: location.column))
        }
    }

    private func updateMarks() {
        guard let model, let url = openURL else {
            code.markedLines = []
            return
        }
        code.markedLines = Set(model.breakpoints.filter { $0.url == url && $0.enabled }.map {
            displayLine(forOriginal: $0.resolvedLine ?? $0.line, column: $0.column ?? 0)
        })
    }

    private func conditionalBreakpoint(at line: Int) {
        guard let model, let url = openURL, let window else { return }
        let location = originalLocation(forDisplayLine: line)
        let existing = model.breakpoints.firstIndex { $0.url == url && $0.line == location.line && $0.column == location.column }
        askCondition(existing.map { model.breakpoints[$0].condition } ?? "", line: line + content.firstLine + 1, in: window) { condition in
            if let existing {
                model.setCondition(condition, at: existing)
            } else {
                var breakpoint = SourcesModel.Breakpoint(url: url, line: location.line, column: location.column)
                breakpoint.condition = condition
                model.add(breakpoint)
            }
        }
    }

    func askCondition(_ current: String, line: Int, in window: NSWindow, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Breakpoint condition"
        alert.informativeText = "Pause on line \(line) only when this expression is true."
        let field = NSTextField(string: current)
        field.font = InspectorTheme.mono(12)
        field.placeholderString = "e.g. count > 3"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { done(field.stringValue) }
        }
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard model != nil, openKey != nil, content.error == nil else { return menu }
        let shownLine = Self.line(at: charIndex, in: view.string)
        menu.insertItem(.separator(), at: 0)
        var index = 0
        if let model, model.paused, let key = openKey {
            let location = originalLocation(forDisplayLine: shownLine)
            if let script = model.scriptID(at: key, line: location.line) {
                let item = NSMenuItem(title: "Continue to Here", action: nil, keyEquivalent: "")
                let target = ClosureTarget { model.continueTo(scriptID: script, line: location.line, column: location.column ?? 0) }
                item.target = target
                item.action = #selector(ClosureTarget.fire(_:))
                item.representedObject = target
                menu.insertItem(item, at: index)
                index += 1
            }
        }
        if openURL != nil {
            for (title, run) in [("Toggle Breakpoint", { [weak self] in self?.gutterClicked(shownLine) }),
                                 ("Add Conditional Breakpoint…", { [weak self] in self?.conditionalBreakpoint(at: shownLine) })] as [(String, () -> Void)] {
                let target = ClosureTarget(run)
                let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                menu.insertItem(item, at: index)
                index += 1
            }
            if let url = openURL {
                let target = ClosureTarget { Format.copy(url) }
                let item = NSMenuItem(title: "Copy Link Address", action: #selector(ClosureTarget.fire(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                menu.insertItem(item, at: index)
            }
        }
        return menu
    }

    private func pauseChanged() {
        updateControls()
        debuggerSource.reload()
        guard let model else { return }
        if let pause = model.pause {
            banner.show(pause)
            banner.isHidden = false
            if pause.frames.indices.contains(model.selectedFrame) {
                let frame = pause.frames[model.selectedFrame]
                if let location = frame.obj("location"), let script = location.str("scriptId") {
                    open(model.key(forScript: script), line: location.int("lineNumber") ?? 0, column: location.int("columnNumber") ?? 0)
                }
            }
        } else {
            banner.isHidden = true
        }
        updateHighlight()
        needsLayout = true
    }

    private func updateHighlight() {
        guard let model, let pause = model.pause, pause.frames.indices.contains(model.selectedFrame),
              let location = pause.frames[model.selectedFrame].obj("location"), let script = location.str("scriptId"),
              model.key(forScript: script) == openKey, content.error == nil else {
            code.highlightedLine = nil
            return
        }
        code.highlightedLine = displayLine(forOriginal: location.int("lineNumber") ?? 0, column: location.int("columnNumber") ?? 0)
    }

    private func togglePause() {
        guard let model else { return }
        if model.paused { model.resume() } else { model.pauseNow() }
    }

    private func showExceptionsMenu() {
        guard let model else { return }
        let menu = NSMenu()
        for (state, title) in [("none", "Don't Pause on Exceptions"), ("uncaught", "Pause on Uncaught Exceptions"),
                               ("all", "Pause on All Exceptions")] {
            menu.add(title, state: model.pauseOnExceptions == state) { model.setPauseOnExceptions(state) }
        }
        exceptions.popUp(menu)
    }

    private func updateControls() {
        let paused = model?.paused ?? false
        let attached = model != nil
        pauseButton.setSymbol(paused ? "play.fill" : "pause.fill")
        pauseButton.toolTip = paused ? "Resume script execution  ⌘\\  F8" : "Pause script execution  ⌘\\  F8"
        pauseButton.isOn = paused
        pauseButton.isEnabled = attached
        for button in [stepOverButton, stepIntoButton, stepOutButton] { button.isEnabled = paused }
        deactivate.isOn = !(model?.breakpointsActive ?? true)
        deactivate.isEnabled = attached
        exceptions.isOn = (model?.pauseOnExceptions ?? "none") != "none"
        exceptions.isEnabled = attached
        let formattable = content.error == nil && (content.language == .javascript || content.language == .css) && openKey != nil
        pretty.isEnabled = formattable
        pretty.isOn = prettyText != nil
        navigatorToggle.isOn = !navigatorPane.isHidden
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isShown, let model, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let characters = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, flags) {
        case (100, []): togglePause(); return true
        case (109, []) where model.paused: model.stepOver(); return true
        case (103, []) where model.paused: model.stepInto(); return true
        case (103, [.shift]) where model.paused: model.stepOut(); return true
        default: break
        }
        if flags == [.command], characters == "\\" { togglePause(); return true }
        if model.paused {
            if flags == [.command], characters == "'" { model.stepOver(); return true }
            if flags == [.command], characters == ";" { model.stepInto(); return true }
            if flags == [.command, .shift], characters == ";" || characters == ":" { model.stepOut(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func focusFilter() {
        if navigatorPane.isHidden { setNavigatorShown(true) }
        window?.makeFirstResponder(filter)
    }

    fileprivate func selectFrame(_ index: Int) {
        model?.selectFrame(index)
    }

    fileprivate func revealBreakpoint(_ breakpoint: SourcesModel.Breakpoint) {
        open(.url(breakpoint.url), line: breakpoint.resolvedLine ?? breakpoint.line, column: breakpoint.column ?? 0)
    }

    fileprivate func editCondition(at index: Int) {
        guard let model, model.breakpoints.indices.contains(index), let window else { return }
        let breakpoint = model.breakpoints[index]
        askCondition(breakpoint.condition, line: breakpoint.line + 1, in: window) { model.setCondition($0, at: index) }
    }

    fileprivate func addWatch() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Watch expression"
        alert.informativeText = "Evaluated in the selected call frame while paused, and in the page otherwise."
        let field = NSTextField(string: "")
        field.font = InspectorTheme.mono(12)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let expression = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !expression.isEmpty else { return }
            Watches.add(expression)
            self?.debuggerSource.reload()
        }
    }
}

private final class SourceTreeNode {
    let name: String
    var children: [SourceTreeNode] = []
    weak var parent: SourceTreeNode?
    var url: String?
    var language = CodeLanguage.plain
    var isPage = false
    var isOrigin = false
    var detail: String?

    init(name: String) { self.name = name }

    func child(_ name: String) -> SourceTreeNode {
        if let existing = children.first(where: { $0.name == name && $0.url == nil }) { return existing }
        let node = SourceTreeNode(name: name)
        node.parent = self
        children.append(node)
        return node
    }

    func sort() {
        children.sort { a, b in
            if (a.url == nil) != (b.url == nil) { return a.url == nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in children { child.sort() }
    }
}

@MainActor
private final class NavigatorSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var roots: [SourceTreeNode] = []
    var onOpen: ((String) -> Void)?
    var ignoringSelection = false
    private var byURL: [String: SourceTreeNode] = [:]

    func node(for url: String) -> SourceTreeNode? { byURL[url] }

    func build(urls: [String], query: String, pageHost: String?, language: (String) -> CodeLanguage) {
        byURL = [:]
        if !query.isEmpty {
            roots = urls.filter { $0.lowercased().contains(query) }.map { url in
                let parts = URLComponents(string: url)
                let name = Self.fileName(parts, url)
                let node = SourceTreeNode(name: name)
                node.url = url
                node.language = language(url)
                node.detail = parts.map { ($0.host ?? "") + ($0.path as NSString).deletingLastPathComponent }
                byURL[url] = node
                return node
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return
        }
        var origins: [String: SourceTreeNode] = [:]
        for url in urls {
            let parts = URLComponents(string: url)
            let originName: String = {
                guard let parts else { return "(no domain)" }
                if parts.scheme == "file" { return "file://" }
                guard let host = parts.host, !host.isEmpty else { return "(no domain)" }
                return parts.port.map { "\(host):\($0)" } ?? host
            }()
            let origin = origins[originName] ?? {
                let node = SourceTreeNode(name: originName)
                node.isOrigin = true
                node.isPage = parts?.host == pageHost && pageHost != nil
                origins[originName] = node
                return node
            }()
            var folder = origin
            let components = (parts?.path ?? "").split(separator: "/").map(String.init)
            for component in components.dropLast() { folder = folder.child(component) }
            if let parts, parts.path.hasSuffix("/"), let last = components.last { folder = folder.child(last) }
            let file = SourceTreeNode(name: Self.fileName(parts, url))
            file.url = url
            file.language = language(url)
            file.parent = folder
            folder.children.append(file)
            byURL[url] = file
        }
        roots = origins.values.sorted { a, b in
            if a.isPage != b.isPage { return a.isPage }
            return a.name < b.name
        }
        for root in roots { root.sort() }
    }

    private static func fileName(_ parts: URLComponents?, _ url: String) -> String {
        guard let parts else { return url }
        let name = parts.path.hasSuffix("/") || parts.path.isEmpty ? "(index)" : (parts.path as NSString).lastPathComponent
        return parts.query.map { "\(name)?\($0)" } ?? name
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SourceTreeNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SourceTreeNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SourceTreeNode)?.url == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SourceTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("source.node")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? IconCell ?? IconCell(identifier: identifier)
        let symbol: String
        let tint: NSColor
        if node.isOrigin {
            symbol = node.name == "file://" ? "internaldrive" : "globe"
            tint = .secondaryLabelColor
        } else if node.url == nil {
            symbol = "folder"
            tint = InspectorTheme.link
        } else {
            switch node.language {
            case .javascript: (symbol, tint) = ("curlybraces", InspectorTheme.warning)
            case .css: (symbol, tint) = ("paintbrush", InspectorTheme.type)
            case .html: (symbol, tint) = ("chevron.left.forwardslash.chevron.right", InspectorTheme.tag)
            case .json: (symbol, tint) = ("curlybraces.square", InspectorTheme.number)
            case .plain: (symbol, tint) = ("doc", .secondaryLabelColor)
            }
        }
        let text = NSMutableAttributedString().add(node.name, .labelColor, font: InspectorTheme.font)
        if let detail = node.detail, !detail.isEmpty { text.add("  " + detail, .tertiaryLabelColor, font: Theme.font(10.5)) }
        cell.set(symbol: symbol, tint: tint, text: text)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { InspectorRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !ignoringSelection, let outline = notification.object as? NSOutlineView,
              let node = outline.item(atRow: outline.selectedRow) as? SourceTreeNode else { return }
        if let url = node.url {
            onOpen?(url)
        } else if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }
}

private final class IconCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(symbol: String, tint: NSColor, text: NSAttributedString) {
        icon.image = .symbol(symbol, size: 10.5, weight: .medium)
        icon.contentTintColor = tint
        label.attributedStringValue = text
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 0, width: 16, height: bounds.height)
        label.frame = NSRect(x: 19, y: (bounds.height - 15) / 2, width: max(bounds.width - 21, 0), height: 15)
    }
}

private final class SourceTitleView: HoverView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ name: String?, detail: String?) {
        let text = NSMutableAttributedString()
        if let name {
            text.add(name, .labelColor, font: Theme.font(11.5, .medium))
            if let detail { text.add("  " + detail, .tertiaryLabelColor, font: Theme.font(10.5)) }
        }
        label.attributedStringValue = text
        toolTip = name
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 5, y: (bounds.height - 15) / 2, width: max(bounds.width - 10, 0), height: 15)
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? Theme.faint(0.06).cgColor : nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private final class PausedBanner: FlippedView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.image = .symbol("pause.circle.fill", size: 12)
        icon.contentTintColor = InspectorTheme.warning
        label.font = Theme.font(11.5, .medium)
        label.maximumNumberOfLines = 3
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = InspectorTheme.warningFill.cgColor
        }
    }

    func show(_ pause: SourcesModel.Pause) {
        var text: String
        switch pause.reason {
        case "exception", "promiseRejection":
            text = pause.reason == "exception" ? "Paused on exception" : "Paused on promise rejection"
            if let data = pause.data, let description = data.str("description") ?? data.str("value") {
                text += ": " + (description.split(separator: "\n").first.map(String.init) ?? description)
            }
        case "debugCommand": text = "Paused"
        case "DOM": text = "Paused on a DOM breakpoint"
        case "XHR": text = "Paused on a fetch or XHR breakpoint"
        case "EventListener": text = "Paused on an event listener"
        case "assert": text = "Paused on an assertion"
        case "step": text = "Paused"
        default: text = pause.hitBreakpoints.isEmpty ? "Paused on a debugger statement" : "Paused on breakpoint"
        }
        label.stringValue = text
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        let size = label.sizeThatFits(NSSize(width: max(width - 36, 40), height: 100))
        return max(size.height + 12, 26)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 6, width: 16, height: 15)
        label.frame = NSRect(x: 28, y: 6, width: max(bounds.width - 36, 0), height: max(bounds.height - 12, 0))
    }
}

@MainActor
private enum Watches {
    static let key = "inspector.watches"
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ expression: String) { UserDefaults.standard.set(all + [expression], forKey: key) }
    static func remove(at index: Int) {
        var list = all
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        UserDefaults.standard.set(list, forKey: key)
    }
}

private final class DebuggerSection {
    enum Kind { case watch, callStack, scope, breakpoints }
    let kind: Kind
    var title: String {
        switch kind {
        case .watch: "Watch"
        case .callStack: "Call Stack"
        case .scope: "Scope"
        case .breakpoints: "Breakpoints"
        }
    }
    init(_ kind: Kind) { self.kind = kind }
}

private final class FrameRow {
    let index: Int
    let frame: JSON
    init(index: Int, frame: JSON) { self.index = index; self.frame = frame }
}

private final class AsyncRow {
    let text: String
    let heading: Bool
    init(_ text: String, heading: Bool) { self.text = text; self.heading = heading }
}

private final class BreakpointRow {
    let index: Int
    init(_ index: Int) { self.index = index }
}

private final class InfoRow {
    let text: String
    let action: (() -> Void)?
    init(_ text: String, action: (() -> Void)? = nil) { self.text = text; self.action = action }
}

private final class WatchNode: ValueNode {
    let index: Int
    var result: RemoteValueNode?
    var error: String?

    init(index: Int, expression: String) {
        self.index = index
        super.init(name: expression)
    }

    override var isExpandable: Bool { result?.isExpandable ?? false }

    override func valueText() -> NSAttributedString {
        if let error { return NSMutableAttributedString().add(error, .tertiaryLabelColor) }
        return result?.valueText() ?? NSMutableAttributedString().add("…", .tertiaryLabelColor)
    }

    override func load(_ done: @escaping @MainActor () -> Void) {
        guard let result else { return done() }
        result.load { [weak self] in
            self?.children = result.children
            done()
        }
    }

    override var copyText: String { result?.copyText ?? "" }
}

@MainActor
private final class DebuggerSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var outline: NSOutlineView?
    weak var panel: SourcesPanel?
    var model: SourcesModel?
    weak var session: InspectorSession?
    private let sections = [DebuggerSection(.watch), DebuggerSection(.callStack), DebuggerSection(.scope),
                            DebuggerSection(.breakpoints)]
    private var watches: [WatchNode] = []
    private var frames: [Any] = []
    private var scopes: [ValueNode] = []
    private var breakpointRows: [BreakpointRow] = []
    private var collapsed: Set<ObjectIdentifier> = []
    private var evaluation = 0

    func reload() {
        guard let outline else { return }
        let pause = model?.pause
        frames = pause.map { pause in
            var rows: [Any] = pause.frames.enumerated().map { FrameRow(index: $0.offset, frame: $0.element) }
            if rows.isEmpty { rows = [InfoRow("No frames")] }
            var trace = pause.asyncTrace
            var depth = 0
            while let current = trace, depth < 8 {
                rows.append(AsyncRow(current.str("description").map { "async \($0)" } ?? "async", heading: true))
                for frame in current.list("callFrames") {
                    let name = (frame.str("functionName") ?? "").isEmpty ? "(anonymous)" : frame.str("functionName")!
                    let file = (URLComponents(string: frame.str("url") ?? "")?.path as NSString?)?.lastPathComponent ?? ""
                    rows.append(AsyncRow("\(name)  \(file):\((frame.int("lineNumber") ?? 0) + 1)", heading: false))
                }
                trace = current.obj("parent")
                depth += 1
            }
            return rows
        } ?? [InfoRow("Not paused")]
        if let pause, let model, pause.frames.indices.contains(model.selectedFrame) {
            scopes = scopeNodes(pause.frames[model.selectedFrame], pause: pause)
        } else {
            scopes = []
        }
        breakpointRows = (model?.breakpoints.indices).map { $0.map(BreakpointRow.init) } ?? []
        watches = Watches.all.enumerated().map { WatchNode(index: $0.offset, expression: $0.element) }
        evaluateWatches()
        outline.reloadData()
        for section in sections where !collapsed.contains(ObjectIdentifier(section)) {
            outline.expandItem(section)
        }
        if let local = scopes.first, !collapsed.contains(ObjectIdentifier(sections[2])) { expand(local) }
    }

    private func expand(_ node: ValueNode) {
        node.load { [weak self] in
            self?.outline?.reloadItem(node, reloadChildren: true)
            self?.outline?.expandItem(node)
        }
    }

    private func scopeNodes(_ frame: JSON, pause: SourcesModel.Pause) -> [ValueNode] {
        let session = session
        return frame.list("scopeChain").compactMap { scope -> ValueNode? in
            guard let object = scope.obj("object") else { return nil }
            let type = scope.str("type") ?? "local"
            var title: String = switch type {
            case "local": "Local"
            case "closure": "Closure"
            case "block": "Block"
            case "script": "Script"
            case "global": "Global"
            case "with": "With Block"
            case "catch": "Catch"
            case "module": "Module"
            case "eval": "Eval"
            default: type.capitalized
            }
            if type == "closure", let name = scope.str("name"), !name.isEmpty { title += " (\(name))" }
            let isLocal = type == "local"
            return GroupNode(name: title, loader: { done in
                let holder = RemoteValueNode(name: "", object: object, session: session)
                holder.load {
                    var nodes = (holder.children ?? []).filter { $0.name != "[[Prototype]]" }
                    if isLocal {
                        var extra: [ValueNode] = []
                        if pause.reason == "exception" || pause.reason == "promiseRejection", let data = pause.data {
                            extra.append(RemoteValueNode(name: "Exception", object: data, session: session))
                        }
                        if let value = frame.obj("returnValue") {
                            extra.append(RemoteValueNode(name: "Return value", object: value, session: session))
                        }
                        if let this = frame.obj("this") {
                            extra.append(RemoteValueNode(name: "this", object: this, session: session))
                        }
                        nodes = extra + nodes
                    }
                    done(nodes)
                }
            })
        }
    }

    private func evaluateWatches() {
        guard let session, !watches.isEmpty else { return }
        evaluation += 1
        let token = evaluation
        let frameID = model?.selectedCallFrameID
        for watch in watches {
            var params: JSON = ["expression": watch.name, "silent": true, "generatePreview": true]
            let method: String
            if let frameID {
                method = "Debugger.evaluateOnCallFrame"
                params["callFrameId"] = frameID
            } else {
                method = "Runtime.evaluate"
                if let context = session.mainContextID { params["contextId"] = context }
            }
            session.call(method, params) { [weak self, weak watch] result, error in
                guard let self, let watch, token == evaluation else { return }
                if let exception = result?.obj("exceptionDetails") {
                    watch.error = exception.obj("exception")?.str("description")?.split(separator: "\n").first.map(String.init)
                        ?? exception.str("text") ?? "Error"
                } else if let object = result?.obj("result") {
                    watch.result = RemoteValueNode(name: watch.name, object: object, session: session)
                } else {
                    watch.error = error ?? "Not available"
                }
                outline?.reloadItem(watch, reloadChildren: false)
            }
        }
    }

    private func children(of item: Any?) -> [Any] {
        guard let item else { return sections }
        if let section = item as? DebuggerSection {
            switch section.kind {
            case .watch:
                return watches + [InfoRow("Add watch expression…") { [weak self] in self?.panel?.addWatch() }]
            case .callStack:
                return frames
            case .scope:
                return model?.paused == true ? scopes : [InfoRow("Not paused")]
            case .breakpoints:
                return breakpointRows.isEmpty ? [InfoRow("No breakpoints")] : breakpointRows
            }
        }
        if let node = item as? ValueNode { return node.children ?? [] }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is DebuggerSection { return true }
        return (item as? ValueNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let section = item as? DebuggerSection {
            collapsed.remove(ObjectIdentifier(section))
            return true
        }
        guard let node = item as? ValueNode else { return false }
        if node.children != nil { return true }
        expand(node)
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if let section = item as? DebuggerSection { collapsed.insert(ObjectIdentifier(section)) }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is DebuggerSection ? 22 : 19
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = InspectorRowView()
        if item is DebuggerSection { row.fill = InspectorTheme.bar }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FrameRow || item is BreakpointRow || item is ValueNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let text = NSMutableAttributedString()
        switch item {
        case let section as DebuggerSection:
            text.add(section.title, .secondaryLabelColor, font: Theme.font(11, .semibold))
            if section.kind == .breakpoints, let model, !model.breakpointsActive {
                text.add("  deactivated", .tertiaryLabelColor, font: Theme.font(10.5))
            }
        case let row as FrameRow:
            let selected = row.index == model?.selectedFrame
            var name = row.frame.str("functionName") ?? ""
            if name.isEmpty { name = "(anonymous)" }
            text.add(selected ? "▸ " : "   ", InspectorTheme.link, font: InspectorTheme.font)
            text.add(name, .labelColor, font: selected ? Theme.font(11.5, .semibold) : InspectorTheme.font)
            if let location = row.frame.obj("location") {
                let file = location.str("scriptId").map { scriptLabel($0) } ?? ""
                text.add("  \(file):\((location.int("lineNumber") ?? 0) + 1)", .tertiaryLabelColor, font: Theme.font(10.5))
            }
        case let row as BreakpointRow:
            guard let model, model.breakpoints.indices.contains(row.index) else { return nil }
            return breakpointCell(outlineView, model.breakpoints[row.index], index: row.index)
        case let row as AsyncRow:
            text.add(row.heading ? row.text : "   " + row.text, .tertiaryLabelColor,
                     font: row.heading ? Theme.font(10.5, .semibold) : InspectorTheme.font)
        case let info as InfoRow:
            text.add(info.text, info.action == nil ? .tertiaryLabelColor : InspectorTheme.link, font: InspectorTheme.font)
        case let group as GroupNode:
            text.add(group.name, .labelColor, font: InspectorTheme.font)
        case let node as ValueNode:
            text.add(node.name, node.dimmed ? InspectorTheme.property.withAlphaComponent(0.6) : InspectorTheme.property)
            text.add(": ", .secondaryLabelColor)
            text.append(node.valueText())
        default:
            return nil
        }
        return InspectorTable.cell(outlineView, "debugger", text)
    }

    private func scriptLabel(_ id: String) -> String {
        guard let url = model?.scripts[id]?.url, !url.isEmpty, let parts = URLComponents(string: url) else { return "VM\(id)" }
        let name = (parts.path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "(index)" : name
    }

    private func breakpointCell(_ outline: NSOutlineView, _ breakpoint: SourcesModel.Breakpoint, index: Int) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("breakpoint")
        let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? BreakpointCell ?? BreakpointCell(identifier: identifier)
        let name = URLComponents(string: breakpoint.url).map { ($0.path as NSString).lastPathComponent } ?? breakpoint.url
        let text = NSMutableAttributedString()
            .add("\(name.isEmpty ? "(index)" : name):\((breakpoint.resolvedLine ?? breakpoint.line) + 1)", .labelColor, font: InspectorTheme.font)
        if !breakpoint.condition.isEmpty { text.add("  if " + breakpoint.condition, InspectorTheme.keyword) }
        if let line = model?.cachedLine(breakpoint.url, breakpoint.resolvedLine ?? breakpoint.line), !line.isEmpty {
            text.add("  " + line.clipped(80), .secondaryLabelColor)
        }
        cell.configure(enabled: breakpoint.enabled, text: text) { [weak self] on in self?.model?.setEnabled(on, at: index) }
        return cell
    }

    @objc func clicked(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0 else { return }
        switch outline.item(atRow: outline.clickedRow) {
        case let row as FrameRow:
            panel?.selectFrame(row.index)
        case let row as BreakpointRow:
            guard let model, model.breakpoints.indices.contains(row.index) else { return }
            panel?.revealBreakpoint(model.breakpoints[row.index])
        case let info as InfoRow:
            info.action?()
        default:
            break
        }
    }

    func menu(_ row: Int) -> NSMenu? {
        guard let outline else { return nil }
        let menu = NSMenu()
        switch outline.item(atRow: row) {
        case let row as BreakpointRow:
            guard let model, model.breakpoints.indices.contains(row.index) else { return nil }
            let index = row.index
            menu.add("Edit Condition…") { [weak self] in self?.panel?.editCondition(at: index) }
            menu.add("Remove Breakpoint") { model.remove(at: index) }
            menu.addItem(.separator())
            menu.add("Enable All Breakpoints") { for i in model.breakpoints.indices { model.setEnabled(true, at: i) } }
            menu.add("Disable All Breakpoints") { for i in model.breakpoints.indices { model.setEnabled(false, at: i) } }
            menu.add("Remove All Breakpoints") { model.removeAll() }
        case let row as FrameRow:
            let frames = model?.pause?.frames ?? []
            menu.add("Copy Stack Trace") { [weak self] in
                let lines = frames.map { frame -> String in
                    let name = (frame.str("functionName") ?? "").isEmpty ? "(anonymous)" : frame.str("functionName")!
                    let location = frame.obj("location")
                    let file = location?.str("scriptId").flatMap { self?.model?.scripts[$0]?.url } ?? ""
                    return "\(name) (\(file):\((location?.int("lineNumber") ?? 0) + 1))"
                }
                Format.copy(lines.joined(separator: "\n"))
            }
            _ = row
        case let watch as WatchNode:
            let index = watch.index
            menu.add("Delete Watch Expression") { [weak self] in
                Watches.remove(at: index)
                self?.reload()
            }
            menu.add("Copy Value") { Format.copy(watch.copyText) }
        case let node as ValueNode:
            menu.add("Copy Value") { Format.copy(node.copyText) }
            if !node.name.isEmpty { menu.add("Copy Property Name") { Format.copy(node.name) } }
            if let section = outline.parent(forItem: node) as? DebuggerSection, section.kind == .watch { break }
            if let remote = node as? RemoteValueNode, let session, let id = remote.object.str("objectId") {
                menu.add("Store as Global Variable") {
                    session.call("Runtime.callFunctionOn", [
                        "objectId": id, "functionDeclaration":
                            "function(){ let i = 1; while (('temp' + i) in globalThis) i++; globalThis['temp' + i] = this; console.log('temp' + i) }",
                    ])
                }
            }
        case let section as DebuggerSection where section.kind == .watch:
            menu.add("Add Watch Expression…") { [weak self] in self?.panel?.addWatch() }
            menu.add("Refresh") { [weak self] in self?.reload() }
        default:
            return nil
        }
        return menu
    }
}

private final class BreakpointCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private var toggle: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.controlSize = .small
        checkbox.onAction { [weak self] in
            guard let self else { return }
            toggle?(checkbox.state == .on)
        }
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(checkbox)
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(enabled: Bool, text: NSAttributedString, toggle: @escaping (Bool) -> Void) {
        checkbox.state = enabled ? .on : .off
        label.attributedStringValue = text
        label.alphaValue = enabled ? 1 : 0.5
        self.toggle = toggle
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 18, height: 16)
        label.frame = NSRect(x: 20, y: (bounds.height - 15) / 2, width: max(bounds.width - 22, 0), height: 15)
    }
}
