import Foundation

let guide = """
mbga: drive the MBGA browser. Pages come back as short outlines with refs
([e12]) to act on; refs last until the page changes, then snapshot again.

  tabs [--all]                 list tabs (* on screen, > the one you use)
  open <url|search> [--focus]  new tab (behind the person's unless --focus)
  use tN | focus [tN] | close [tN]
  goto <url> | back | forward | reload [--hard]
  info                         title, url, status, console counts
  snapshot [--text] [--viewport] [--max N]
                               headings and everything usable, with refs;
                               --text adds paragraphs and list items
  read [--all] [--max N]       the page's text (main content by default)
  find <text>                  elements saying <text>, with refs
  click <ref> [--force]        real click; says where the page went
  fill <ref> <text> [--enter]  replace a field's text (type --append adds)
  press <key> [--times N]      Enter, Tab, Escape, ArrowDown, Shift+Tab, a…
  select <ref> <option>        choose in a <select>
  hover <ref> | scroll [down|up|top|bottom|<ref>] [px]
  wait load | idle | <ms> | text <t> | gone <t>   [--timeout s]
                               idle: no requests for half a second
  eval <js> [--timeout s]      run JavaScript in the page, print JSON
  screenshot [--full] [--out path]   PNG at CSS pixels; prints its path
  console [--errors] [--clear] messages since the page loaded
  network [--failed] [--api] [--filter t] [--max N] | network --body N
                               requests since you first used the tab

Refs can also be css=<selector> or text=<words> when you know the page.

  run <file.js | - | -e 'code'> [--tab tN] [--timeout s]
      a script, run inside MBGA, with every command as an async function
      returning its text: open(url) → "tN", goto, click(target), fill(target,
      text, {enter: true}), press, select, wait('load' | ms | {text}),
      snapshot, read, find, screenshot, plus evaluate(fn, ...args) → the
      value fn returns in the page, and log(...). Whatever the script logs
      or returns is printed. One call for many steps:
        mbga run -e 'await open("news.ycombinator.com");
          return await evaluate(() => [...document.querySelectorAll(".titleline > a")]
            .slice(0, 5).map(a => a.textContent))'

Every page command takes --tab tN (default: the tab you opened or chose
last, else the one on screen). Set MBGA_SESSION=<name> to keep your own
current tab apart from other agents'. Your tabs open in the Agents space,
off the person's screen. Refs in cross-site frames look like f1:e3.

Typical loop: open → snapshot → click/fill → snapshot. open, goto and
click wait for the page to load and its requests to quiet down, so there's
no need to sleep; for content that comes later, wait text <t>. Prefer
snapshot/read/find over screenshots: far fewer tokens.
"""

let socketPath = ProcessInfo.processInfo.environment["MBGA_SOCKET"]
    ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MBGA/agent.sock").path

enum Failure: Error {
    case message(String)
}

final class Browser {
    private let fd: Int32
    private var pending = Data()
    private let session: String

    init(session: String = ProcessInfo.processInfo.environment["MBGA_SESSION"] ?? "default") throws {
        self.session = session
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(socketPath.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, connected == 0 else {
            close(fd)
            throw Failure.message("Can't reach MBGA. Open it and turn on Settings ▸ Agents ▸ \"Let agents use MBGA\".")
        }
    }

    deinit { close(fd) }

    func run(_ argv: [String]) throws -> String {
        var request = try JSONSerialization.data(withJSONObject: ["argv": argv, "session": session])
        request.append(0x0A)
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else { throw Failure.message("MBGA closed the connection.") }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let reply = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw Failure.message("MBGA sent something unexpected.")
                }
                if reply["ok"] as? Bool == true { return reply["text"] as? String ?? "" }
                throw Failure.message(reply["error"] as? String ?? "The command failed.")
            }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw Failure.message("MBGA closed the connection.") }
            pending.append(contentsOf: buffer[0..<count])
        }
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty || ["help", "-h", "--help", "guide"].contains(argv[0]) {
    print(guide)
    exit(0)
}
do {
    var argv = argv
    if argv[0] == "run" {
        var rest: [String] = []
        var source: String?
        var words = argv.dropFirst()
        while let word = words.popFirst() {
            if source == nil, word == "-e" {
                guard let code = words.popFirst() else { break }
                source = code
            } else if word.hasPrefix("--") {
                rest.append(word)
                if ["--tab", "--timeout"].contains(word), let value = words.popFirst() { rest.append(value) }
            } else if word == "-t", let value = words.popFirst() {
                rest += ["--tab", value]
            } else if source == nil, word == "-" {
                source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else if source == nil {
                guard let text = try? String(contentsOfFile: word, encoding: .utf8) else { throw Failure.message("Can't read \(word).") }
                source = text
            } else {
                rest.append(word)
            }
        }
        guard let source else { throw Failure.message("Usage: mbga run <file.js | - | -e 'code'> [--tab tN] [--timeout s]") }
        argv = ["run", source] + rest
    }
    print(try Browser().run(argv))
} catch Failure.message(let text) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
