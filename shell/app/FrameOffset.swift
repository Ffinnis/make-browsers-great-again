import AppKit

@MainActor
enum FrameOffset {
    static func find(_ url: String, frame: String, in view: MBWebView, _ done: @escaping (CGPoint) -> Void) {
        guard !frame.isEmpty, let origin = PasswordFiller.origin(url) else { return done(.zero) }
        let script = """
        (() => { const o = \(FormScript.literal(origin)); const f = [...document.querySelectorAll('iframe, frame')]
          .find(f => { try { return new URL(f.src, location.href).origin === o; } catch { return false; } });
          if (!f) return null; const r = f.getBoundingClientRect(), s = getComputedStyle(f);
          return [r.left + f.clientLeft + parseFloat(s.paddingLeft), r.top + f.clientTop + parseFloat(s.paddingTop)]; })()
        """
        let params = (try? JSONSerialization.data(withJSONObject: ["expression": script, "returnByValue": true]))
            .flatMap { String(data: $0, encoding: .utf8) }
        view.sendDevToolsCommand("Runtime.evaluate", params: params) { result, _ in
            MainActor.assumeIsolated {
                guard let data = result?.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let point = (json["result"] as? [String: Any])?["value"] as? [Double], point.count == 2
                else { return done(.zero) }
                done(CGPoint(x: point[0], y: point[1]))
            }
        }
    }
}
