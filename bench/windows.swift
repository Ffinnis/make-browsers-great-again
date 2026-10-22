import CoreGraphics
import Foundation

let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
if CommandLine.arguments.contains("--bounds") {
    let frames = mine.compactMap { $0[kCGWindowBounds as String] }
    print(String(decoding: try JSONSerialization.data(withJSONObject: frames), as: UTF8.self))
} else {
    print(mine.count)
}
