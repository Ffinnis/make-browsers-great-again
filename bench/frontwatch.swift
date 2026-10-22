import AppKit

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]),
      let seconds = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("usage: frontwatch <pid> <seconds>\n".utf8))
    exit(2)
}
var samples = 0, front = 0
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    samples += 1
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { front += 1 }
    usleep(500_000)
}
print(samples > 0 ? Double(front) / Double(samples) : 0)
