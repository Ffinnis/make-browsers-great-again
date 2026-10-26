import AppKit
import NaturalLanguage
import Translation

struct PageLanguage: Equatable {
    let identifier: String
    let code: String
    var onDevice = false
    var fast = false

    var name: String { Locale.current.localizedString(forLanguageCode: code) ?? code }
    var isPreferred: Bool { Self.preferredCodes.contains(code) }

    static var target: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }

    static var targetName: String {
        let code = target.languageCode?.identifier ?? "en"
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static var preferredCodes: Set<String> {
        Set(Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier })
    }

    static var googleTarget: String {
        let language = target
        let code = language.languageCode?.identifier ?? "en"
        guard code == "zh" else { return code }
        return language.script?.identifier == "Hant" || language.region?.identifier == "TW" ? "zh-TW" : "zh-CN"
    }

    init?(identifier: String) {
        guard let code = Locale.Language(identifier: identifier).languageCode?.identifier, code != "und" else { return nil }
        self.identifier = identifier
        self.code = code
    }

    static func detect(declared: String, sample: String) -> Self? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let letters = sample.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.prefix(200).count
        let guess = recognizer.languageHypotheses(withMaximum: 1).first
        let stated = Self(identifier: declared.replacingOccurrences(of: "_", with: "-"))
        if let guess, letters >= 80, guess.value >= 0.6 || stated == nil {
            return Self(identifier: guess.key.rawValue)
        }
        if let stated { return stated }
        guard let guess, letters >= 20 else { return nil }
        return Self(identifier: guess.key.rawValue)
    }

    func checkingDevice() async -> Self {
        guard #available(macOS 26.0, *) else { return self }
        let source = Locale.Language(identifier: identifier)
        var language = self
        if #available(macOS 26.4, *) {
            let quick = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: Self.target)
            language.fast = quick == .installed
        }
        let status = language.fast ? .installed : await LanguageAvailability().status(from: source, to: Self.target)
        language.onDevice = status == .installed
        return language
    }

    @MainActor
    func deviceTranslator() -> TextTranslator? {
        guard onDevice, #available(macOS 26.0, *) else { return nil }
        return DeviceTranslator(source: Locale.Language(identifier: identifier), target: Self.target, fast: fast).translate
    }
}

typealias TextTranslator = @MainActor ([String]) async throws -> [String]

@available(macOS 26.0, *)
@MainActor
private final class DeviceTranslator {
    private let session: TranslationSession

    init(source: Locale.Language, target: Locale.Language, fast: Bool) {
        if fast, #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        var result = texts
        for response in try await session.translations(from: requests) {
            guard let index = response.clientIdentifier.flatMap(Int.init), result.indices.contains(index) else { continue }
            result[index] = response.targetText
        }
        return result
    }
}

struct PageScriptError: Error {
    let message: String
}

@MainActor
private final class Claim {
    private var done = false
    func take() -> Bool {
        defer { done = true }
        return !done
    }
}

@MainActor
enum PageScripts {
    static func send(_ view: MBWebView, _ method: String, _ params: [String: Any] = [:],
                     timeout: TimeInterval = 20) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let claim = Claim()
        let text: String = try await withCheckedThrowingContinuation { continuation in
            view.sendDevToolsCommand(method, params: json) { result, error in
                guard claim.take() else { return }
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: PageScriptError(message: error ?? "\(method) failed"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard claim.take() else { return }
                continuation.resume(throwing: PageScriptError(message: "\(method) timed out"))
            }
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func evaluate(_ view: MBWebView, _ expression: String, in context: Int? = nil,
                         timeout: TimeInterval = 20) async throws -> Any? {
        var params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
        if let context { params["contextId"] = context }
        let result = try await send(view, "Runtime.evaluate", params, timeout: timeout)
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw PageScriptError(message: exception["text"] as? String ?? "The script failed")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    static func isolatedWorld(_ view: MBWebView, named name: String) async throws -> Int {
        let tree = try await send(view, "Page.getFrameTree")
        guard let frame = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String else {
            throw PageScriptError(message: "The page has no frame")
        }
        let world = try await send(view, "Page.createIsolatedWorld", ["frameId": frame, "worldName": name])
        guard let context = world["executionContextId"] as? Int else { throw PageScriptError(message: "No isolated world") }
        return context
    }
}

@MainActor
final class TranslationJob {
    enum Event { case translated, failed, ended }

    private weak var view: MBWebView?
    private let translate: TextTranslator
    private let report: (Event) -> Void
    private var context: Int?
    private var cancelled = false
    private var applied = 0

    init(view: MBWebView, translate: @escaping TextTranslator, report: @escaping (Event) -> Void) {
        self.view = view
        self.translate = translate
        self.report = report
    }

    func start() {
        Task { await run() }
    }

    func cancel(restoring: Bool) {
        cancelled = true
        guard restoring, let view, let context else { return }
        Task { _ = try? await PageScripts.evaluate(view, "globalThis.__mbgaTranslate?.restore()", in: context) }
    }

    private func run() async {
        do {
            guard let view else { return }
            let context = try await PageScripts.isolatedWorld(view, named: "mbga-translate")
            self.context = context
            _ = try await PageScripts.evaluate(view, TranslateScript.setup, in: context)
            var announced = false
            while !cancelled {
                let batch = try await PageScripts.evaluate(view, "__mbgaTranslate.next(20, 1500)", in: context) as? [[Any]] ?? []
                if batch.isEmpty {
                    if !announced, !cancelled { report(.translated) }
                    announced = true
                    let more = try await PageScripts.evaluate(view, "__mbgaTranslate.wait(30000)", in: context, timeout: 45)
                    if more as? Bool == false { break }
                    continue
                }
                try await apply(batch, in: view, context: context)
            }
            if !cancelled { report(.ended) }
        } catch {
            guard !cancelled else { return }
            cancelled = true
            report(applied == 0 && !(error is PageScriptError) ? .failed : .ended)
        }
    }

    private func apply(_ batch: [[Any]], in view: MBWebView, context: Int) async throws {
        let ids = batch.compactMap { $0.first as? Int }
        let texts = batch.map { $0.count > 1 ? $0[1] as? String ?? "" : "" }
        guard ids.count == texts.count else { return }
        let translated = try await translate(texts)
        guard !cancelled else { return }
        let pairs = zip(ids, translated).map { [$0 as Any, $1 as Any] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: pairs), as: UTF8.self)
        _ = try await PageScripts.evaluate(view, "__mbgaTranslate.apply(\(json))", in: context)
        applied += pairs.count
    }
}
