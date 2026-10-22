import Foundation

struct AgentArguments {
    var words: [String] = []
    var flags: [String: String] = [:]
    var session = "default"

    init(_ argv: ArraySlice<String>) {
        var rest = argv[...]
        while let arg = rest.popFirst() {
            if arg.hasPrefix("--"), arg.count > 2 {
                let body = arg.dropFirst(2)
                if let eq = body.firstIndex(of: "=") {
                    flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if ["tab", "max", "out", "timeout", "body", "filter"].contains(body), let value = rest.popFirst() {
                    flags[String(body)] = value
                } else {
                    flags[String(body)] = ""
                }
            } else if arg == "-t", let value = rest.popFirst() {
                flags["tab"] = value
            } else {
                words.append(arg)
            }
        }
    }

    func has(_ flag: String) -> Bool { flags[flag] != nil }
    func int(_ flag: String) -> Int? { flags[flag].flatMap { Int($0) } }
    subscript(_ i: Int) -> String? { words.indices.contains(i) ? words[i] : nil }
}
