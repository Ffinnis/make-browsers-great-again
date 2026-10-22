import AppKit
import Darwin

enum AgentSettings {
    static let enabledKey = "agentAccess"
    static let debug = ProcessInfo.processInfo.environment["MBGA_DEBUG_AGENT"]?.isEmpty == false

    static var enabled: Bool { debug || UserDefaults.standard.bool(forKey: enabledKey) }

    static var commandLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mbga")
    }

    static var bundledCommand: URL? {
        Bundle.main.url(forResource: "mbga", withExtension: nil, subdirectory: "bin")
    }

    static var guide: String {
        guard let command = bundledCommand else { return "" }
        let process = Process()
        process.executableURL = command
        process.arguments = ["help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var claudeSkill: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/mbga-browser/SKILL.md")
    }

    static func installClaudeSkill() -> String? {
        if !FileManager.default.fileExists(atPath: commandLink.path), let error = installCommand() { return error }
        let skill = [
            "---",
            "name: mbga-browser",
            "description: Use the person's MBGA browser from the terminal with the `mbga` command - open pages, read them as compact outlines, click, fill forms, run multi-step scripts, check console errors and network requests. Use it whenever a task involves a website or web app, especially pages that need JavaScript or the person's sign-ins, and to check web work you just built (localhost).",
            "---",
            "",
            "# Using the MBGA browser",
            "",
            "`mbga` (~/.local/bin/mbga) drives the browser the person uses on this Mac. Your tabs open in its Agents space, off the person's screen, so they keep working while you do. Read pages with `snapshot` or `read`, not screenshots: far fewer tokens. When you know the page, write code: `mbga run` executes a whole script in one call, and `mbga eval` runs JavaScript in the page.",
            "",
            "If a command says it can't reach MBGA, ask the person to open MBGA and turn on Settings > Agents.",
            "",
            "```",
            guide,
            "```",
            "",
        ].joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: claudeSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skill.write(to: claudeSkill, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static let instructions = [
        "## Browser",
        "Use the person's MBGA browser from the shell with `mbga` (~/.local/bin/mbga) for anything on the web: `mbga open <url>`, `mbga snapshot` (the page as an outline with refs like [e4]), `mbga click e4`, `mbga fill e6 \"text\" --enter`, `mbga read`, `mbga console`, `mbga network`. For many steps, write a script: `mbga run -e 'await open(url); return await evaluate(() => document.title)'`. Your tabs stay off the person's screen. Run `mbga help` for everything.",
    ].joined(separator: "\n")

    static func installCommand() -> String? {
        guard let command = bundledCommand else { return "The command isn't in this build of MBGA." }
        let link = commandLink
        do {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: command)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

@MainActor
final class AgentServer {
    let path: String
    private let commands: AgentCommands
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(store: BrowserStore, path: String) {
        self.path = path
        commands = AgentCommands(store: store)
        NotificationCenter.default.addObserver(self, selector: #selector(update),
                                               name: UserDefaults.didChangeNotification, object: nil)
        update()
    }

    @objc private func update() {
        if AgentSettings.enabled { start() } else { stop() }
    }

    private func start() {
        guard listener < 0 else { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            NSLog("agent socket path too long: %@", path)
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("agent socket: %s", strerror(errno))
            close(fd)
            return
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
                Thread.detachNewThread { [weak self] in self?.serve(client) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func stop() {
        guard listener >= 0 else { return }
        source?.cancel()
        source = nil
        listener = -1
        unlink(path)
    }

    private nonisolated func serve(_ client: Int32) {
        defer { close(client) }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) & ~O_NONBLOCK)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                let reply = handle(Data(line))
                var out = reply
                out.append(0x0A)
                let written = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                guard written == out.count else { return }
            }
        }
    }

    private nonisolated func handle(_ line: Data) -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let argv = request["argv"] as? [String], !argv.isEmpty
        else { return Self.encode(.failure("Expected {\"argv\": [\"command\", ...]}")) }
        let session = request["session"] as? String ?? "default"
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        Task { @MainActor [weak self] in
            guard let self else {
                result.reply = .failure("MBGA is closing")
                done.signal()
                return
            }
            result.reply = await commands.run(argv, session: session)
            done.signal()
        }
        done.wait()
        return Self.encode(result.reply ?? .failure("No reply"))
    }

    private nonisolated static func encode(_ reply: AgentReply) -> Data {
        let object: [String: Any] = switch reply {
        case .success(let text): ["ok": true, "text": text]
        case .failure(let error): ["ok": false, "error": error]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    }

    private final class Box: @unchecked Sendable {
        var reply: AgentReply?
    }
}

enum AgentReply: Sendable {
    case success(String)
    case failure(String)
}

struct AgentPreferences: Codable, Equatable {
    var ownSpace = true
    var separateProfile = false
    var profileID: UInt64?
    var separateProfileID: UInt64?
    var spaceID: UInt64?
    var blockedSites: [String] = []

    static func load(from directory: URL) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("agents.json")),
              let preferences = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return preferences
    }

    func save(to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: directory.appendingPathComponent("agents.json"), options: .atomic)
    }

    func blockedSite(for url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        return blockedSites.first { site in
            let site = site.lowercased().trimmingCharacters(in: .whitespaces)
            return !site.isEmpty && (host == site || host.hasSuffix("." + site))
        }
    }
}
