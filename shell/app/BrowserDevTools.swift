import Foundation

@MainActor
final class BrowserDevTools {
    typealias Reply = (_ result: [String: Any]?, _ error: String?) -> Void

    var onEvent: ((String, [String: Any], String?) -> Void)?
    let available: Bool
    private var nextID = 0
    private var replies: [Int: Reply] = [:]

    init(available: Bool) {
        self.available = available
        guard available else { return }
        MBEngine.setBrowserDevToolsHandler { [weak self] message in
            MainActor.assumeIsolated { self?.receive(message) }
        }
    }

    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, reply: Reply? = nil) {
        guard available else {
            reply?(nil, "no browser connection")
            return
        }
        nextID += 1
        var message: [String: Any] = ["id": nextID, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        if let reply { replies[nextID] = reply }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        MBEngine.sendBrowserDevToolsMessage(json)
    }

    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            send(method, params, session: session) { result, _ in continuation.resume(returning: result) }
        }
    }

    private func receive(_ message: String) {
        guard let data = message.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            let error = (object["error"] as? [String: Any])?["message"] as? String
            replies.removeValue(forKey: id)?(object["result"] as? [String: Any], error)
        } else if let method = object["method"] as? String {
            onEvent?(method, object["params"] as? [String: Any] ?? [:], object["sessionId"] as? String)
        }
    }
}
