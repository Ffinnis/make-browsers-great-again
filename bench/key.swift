import AppKit

var args = Array(CommandLine.arguments.dropFirst())
var target = "dev.mbga.browser"
if args.first == "--to", args.count > 1 {
    target = args[1]
    args.removeFirst(2)
}
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else {
    FileHandle.standardError.write(Data("\(target) is not frontmost\n".utf8))
    exit(2)
}
var flags: CGEventFlags = []
for m in args.dropFirst() {
    switch m {
    case "cmd": flags.insert(.maskCommand)
    case "ctrl": flags.insert(.maskControl)
    case "shift": flags.insert(.maskShift)
    case "opt": flags.insert(.maskAlternate)
    default: break
    }
}
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(args[0])!, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(30_000)
}
