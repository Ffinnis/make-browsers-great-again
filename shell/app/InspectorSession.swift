import AppKit

typealias JSON = [String: Any]

extension [String: Any] {
    func str(_ key: String) -> String? { self[key] as? String }
    func num(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func obj(_ key: String) -> JSON? { self[key] as? JSON }
    func list(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
}

struct InspectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class Signal<Value> {
    private struct Observer {
        weak var owner: AnyObject?
        let handle: @MainActor (Value) -> Void
    }
    private var observers: [Observer] = []

    func observe(_ owner: AnyObject, _ handle: @escaping @MainActor (Value) -> Void) {
        observers.append(Observer(owner: owner, handle: handle))
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    func send(_ value: Value) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handle(value) }
    }
}

extension Signal where Value == Void {
    func send() { send(()) }
}

@MainActor
final class Coalescer {
    private let delay: TimeInterval
    private var pending = false
    private let work: @MainActor () -> Void

    init(delay: TimeInterval = 0.05, _ work: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.work = work
    }

    func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.work()
            }
        }
    }

    func flush() {
        pending = false
        work()
    }
}

@MainActor
protocol InspectorModel: AnyObject {
    init(session: InspectorSession)
    func start()
    func stop()
}

@MainActor
final class InspectorSession {
    let tabID: UInt64
    private(set) weak var view: MBWebView?
    let navigated = Signal<String>()
    private(set) var url = ""
    private(set) var mainFrameID = ""
    private(set) var contexts: [Int: JSON] = [:]

    private struct Handler {
        weak var owner: AnyObject?
        let prefix: String
        let handle: @MainActor (String, JSON) -> Void
    }
    private var handlers: [Handler] = []
    private var models: [ObjectIdentifier: InspectorModel] = [:]
    private var order: [ObjectIdentifier] = []
    private var stopped = false
    private var deferred: [@MainActor () -> Void] = []

    static let eagerModels: [InspectorModel.Type] = [ConsoleModel.self, NetworkModel.self, SourcesModel.self]

    init(view: MBWebView) {
        tabID = view.tabID
        self.view = view
        view.forwardsDevToolsEvents = true
        on("Page.frameNavigated", self) { [weak self] _, params in
            guard let self, let frame = params.obj("frame"), frame["parentId"] == nil else { return }
            url = frame.str("url") ?? url
            mainFrameID = frame.str("id") ?? mainFrameID
            navigated.send(url)
        }
        on("Runtime.executionContext", self) { [weak self] method, params in
            guard let self else { return }
            switch method {
            case "Runtime.executionContextCreated":
                if let context = params.obj("context"), let id = context.int("id") { contexts[id] = context }
            case "Runtime.executionContextDestroyed":
                if let id = params.int("executionContextId") { contexts[id] = nil }
            case "Runtime.executionContextsCleared":
                contexts = [:]
            default: break
            }
        }
        call("Page.enable")
        call("Runtime.enable")
        Task { [weak self] in
            guard let self, let tree = try? await send("Page.getFrameTree"),
                  let frame = tree.obj("frameTree")?.obj("frame") else { return }
            url = frame.str("url") ?? url
            mainFrameID = frame.str("id") ?? mainFrameID
        }
        for type in Self.eagerModels { _ = model(type) }
    }

    func stop() {
        guard !stopped else { return }
        flushDeferred()
        stopped = true
        for id in order.reversed() { models[id]?.stop() }
        call("Runtime.disable")
        view?.forwardsDevToolsEvents = false
    }

    func model<M: InspectorModel>(_ type: M.Type) -> M {
        let id = ObjectIdentifier(type)
        if let model = models[id] as? M { return model }
        let model = M(session: self)
        models[id] = model
        order.append(id)
        model.start()
        return model
    }

    func existing<M: InspectorModel>(_ type: M.Type) -> M? {
        models[ObjectIdentifier(type)] as? M
    }

    var showPanel: ((InspectorPanelKind) -> Void)?
    var openTab: ((String) -> Void)?
    var developerState: (() -> DevTabState)?
    var updateDeveloperState: (((inout DevTabState) -> Void) -> Void)?
    private(set) var pendingSource: (url: String, line: Int, column: Int)?
    let sourceRequested = Signal<Void>()

    func revealSource(url: String, line: Int, column: Int = 0) {
        pendingSource = (url, line, column)
        showPanel?(.sources)
        sourceRequested.send()
    }

    func takePendingSource() -> (url: String, line: Int, column: Int)? {
        defer { pendingSource = nil }
        return pendingSource
    }

    func revealNode(backendNodeID: Int) {
        showPanel?(.elements)
        model(ElementsModel.self).reveal(backendNodeID: backendNodeID)
    }

    func inspect(at point: NSPoint) {
        showPanel?(.elements)
        _ = model(ElementsModel.self)
        call("DOM.getNodeForLocation", ["x": Int(point.x), "y": Int(point.y), "ignorePointerEventsNone": true]) { [weak self] result, _ in
            guard let self, let id = result?.int("backendNodeId") else { return }
            revealNode(backendNodeID: id)
        }
    }

    var mainContextID: Int? {
        let defaults = contexts.values.filter { $0.obj("auxData")?.bool("isDefault") ?? false }
        return (defaults.first { $0.obj("auxData")?.str("frameId") == mainFrameID } ?? defaults.first)?.int("id")
    }

    func send(_ method: String, _ params: JSON = [:], timeout: TimeInterval = 15) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            call(method, params, timeout: timeout) { result, error in
                if let result { continuation.resume(returning: result) } else {
                    continuation.resume(throwing: InspectorError(error ?? "\(method) failed"))
                }
            }
        }
    }

    func call(_ method: String, _ params: JSON = [:], timeout: TimeInterval = 15,
              _ done: (@MainActor (JSON?, String?) -> Void)? = nil) {
        guard let view, !view.isClosing else {
            done?(nil, "The page is closed.")
            return
        }
        let json = params.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: params))
            .map { String(decoding: $0, as: UTF8.self) }
        var answered = false
        if let done {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard !answered else { return }
                    answered = true
                    done(nil, "The page didn't answer \(method).")
                }
            }
        }
        view.sendDevToolsCommand(method, params: json) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let done, !answered else { return }
                answered = true
                let reply = {
                    if let result {
                        done((try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? JSON ?? [:], nil)
                    } else {
                        done(nil, error ?? "\(method) failed")
                    }
                }
                if let self { self.deliver(reply) } else { reply() }
            }
        }
    }

    func on(_ prefix: String, _ owner: AnyObject, _ handle: @escaping @MainActor (String, JSON) -> Void) {
        handlers.append(Handler(owner: owner, prefix: prefix, handle: handle))
    }

    func receive(_ method: String, _ params: JSON) {
        guard !stopped else { return }
        deliver { [weak self] in self?.dispatch(method, params) }
    }

    private func deliver(_ work: @escaping @MainActor () -> Void) {
        deferred.append(work)
        let container = view?.superview as? WebContainerView
        guard !stopped, container?.heldSize != nil else { return flushDeferred() }
        if deferred.count == 1 { container?.whenSettled { [weak self] in self?.flushDeferred() } }
    }

    private func flushDeferred() {
        while !deferred.isEmpty { deferred.removeFirst()() }
    }

    private func dispatch(_ method: String, _ params: JSON) {
        guard !stopped else { return }
        var stale = false
        for handler in handlers {
            guard handler.owner != nil else {
                stale = true
                continue
            }
            if method.hasPrefix(handler.prefix) { handler.handle(method, params) }
        }
        if stale { handlers.removeAll { $0.owner == nil } }
    }
}

enum RemoteValue {
    static func isExpandable(_ object: JSON) -> Bool {
        object.str("objectId") != nil && object.str("type") == "object" || object.str("type") == "function"
            && object.str("objectId") != nil
    }

    static func summary(_ object: JSON, quoteStrings: Bool = true, preview usePreview: Bool = true) -> String {
        let type = object.str("type") ?? "undefined"
        switch type {
        case "string":
            let value = object.str("value") ?? ""
            return quoteStrings ? "\"\(value)\"" : value
        case "number", "boolean":
            if let unserializable = object.str("unserializableValue") { return unserializable }
            return object["value"].map { "\($0)" }.map { type == "boolean" ? ($0 == "1" ? "true" : $0 == "0" ? "false" : $0) : $0 } ?? ""
        case "bigint":
            return object.str("unserializableValue") ?? ""
        case "undefined":
            return "undefined"
        case "symbol":
            return object.str("description") ?? "Symbol()"
        case "function":
            let description = object.str("description") ?? "function"
            return functionSignature(description)
        default:
            break
        }
        if object.str("subtype") == "null" { return "null" }
        if usePreview, let preview = object.obj("preview") { return summary(preview: preview, depth: 0) }
        return object.str("description") ?? object.str("className") ?? "Object"
    }

    static func functionSignature(_ source: String) -> String {
        let head = source.prefix { $0 != "{" && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        var text = head
        for prefix in ["async function", "function*", "function"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return (prefix == "async function" ? "async ƒ " : "ƒ ") + (text.isEmpty ? "()" : text)
        }
        if text.hasPrefix("class") { return text }
        if text.contains("=>") { return "ƒ " + text.replacingOccurrences(of: " =>", with: "").replacingOccurrences(of: "=>", with: "") }
        return "ƒ " + text
    }

    static func summary(preview: JSON, depth: Int) -> String {
        let subtype = preview.str("subtype")
        let description = preview.str("description") ?? "Object"
        let properties = preview.list("properties")
        let entries = preview.list("entries")
        let more = preview.bool("overflow") ? ", …" : ""
        if subtype == "node" { return description }
        if subtype == "array" || subtype == "typedarray" {
            let items = properties.filter { Int($0.str("name") ?? "") != nil }.map(propertyValue).joined(separator: ", ")
            let digits = description.drop { $0 != "(" }.dropFirst().prefix { $0.isNumber }
            let count = digits.isEmpty ? "" : "(\(digits)) "
            let name = description.hasPrefix("Array") ? "" : String(description.prefix { $0 != "(" }) + " "
            return "\(name)\(count)[\(items)\(more)]"
        }
        if subtype == "map" || subtype == "set" {
            let items = entries.map { entry -> String in
                let value = entry.obj("value").map { summary(preview: $0, depth: depth + 1) } ?? ""
                if let key = entry.obj("key") { return "\(summary(preview: key, depth: depth + 1)) => \(value)" }
                return value
            }
            return "\(description) {\(items.joined(separator: ", "))\(more)}"
        }
        if subtype == "error" || subtype == "regexp" || subtype == "date" { return description }
        if preview.str("type") != "object" { return description }
        let items = properties.map { "\($0.str("name") ?? ""): \(propertyValue($0))" }.joined(separator: ", ")
        let name = description == "Object" ? "" : description + " "
        return "\(name){\(items)\(more)}"
    }

    private static func propertyValue(_ property: JSON) -> String {
        if let nested = property.obj("valuePreview") { return summary(preview: nested, depth: 1) }
        let value = property.str("value") ?? ""
        switch property.str("type") {
        case "string": return "\"\(value)\""
        case "function": return "ƒ"
        case "object":
            if property.str("subtype") == "null" { return "null" }
            if property.str("subtype") == "array" { return value }
            return value == "Object" ? "{…}" : value
        case "accessor": return "(…)"
        default: return value
        }
    }

    static func color(_ object: JSON) -> NSColor {
        switch object.str("type") {
        case "string": InspectorTheme.string
        case "number", "bigint", "boolean": InspectorTheme.number
        case "undefined": .tertiaryLabelColor
        case "symbol": InspectorTheme.string
        case "function": InspectorTheme.keyword
        default: object.str("subtype") == "null" ? .tertiaryLabelColor : .labelColor
        }
    }
}
