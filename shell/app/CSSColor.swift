import AppKit

enum CSSColor {
    static func parse(_ value: String) -> NSColor? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), let number = UInt64(hex, radix: 16) else { return nil }
            func channel(_ shift: Int, _ bits: Int) -> CGFloat {
                let max = bits == 4 ? 15.0 : 255.0
                return CGFloat(Double((number >> UInt64(shift)) & (bits == 4 ? 0xF : 0xFF)) / max)
            }
            switch hex.count {
            case 3: return NSColor(srgbRed: channel(8, 4), green: channel(4, 4), blue: channel(0, 4), alpha: 1)
            case 4: return NSColor(srgbRed: channel(12, 4), green: channel(8, 4), blue: channel(4, 4), alpha: channel(0, 4))
            case 6: return NSColor(srgbRed: channel(16, 8), green: channel(8, 8), blue: channel(0, 8), alpha: 1)
            default: return NSColor(srgbRed: channel(24, 8), green: channel(16, 8), blue: channel(8, 8), alpha: channel(0, 8))
            }
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") {
            let parts = text[text.index(after: open)..<close].split(whereSeparator: { ", /".contains($0) }).map(String.init)
            guard parts.count >= 3 else { return nil }
            func number(_ part: String, scale: Double) -> CGFloat {
                part.hasSuffix("%") ? CGFloat((Double(part.dropLast()) ?? 0) / 100) : CGFloat((Double(part) ?? 0) / scale)
            }
            return NSColor(srgbRed: number(parts[0], scale: 255), green: number(parts[1], scale: 255), blue: number(parts[2], scale: 255),
                           alpha: parts.count > 3 ? number(parts[3], scale: 1) : 1)
        }
        let named: [String: UInt32] = ["white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
                                       "gray": 0x808080, "grey": 0x808080, "orange": 0xFFA500, "yellow": 0xFFFF00, "purple": 0x800080,
                                       "rebeccapurple": 0x663399, "pink": 0xFFC0CB, "silver": 0xC0C0C0, "navy": 0x000080,
                                       "teal": 0x008080, "maroon": 0x800000, "olive": 0x808000, "lime": 0x00FF00, "aqua": 0x00FFFF,
                                       "fuchsia": 0xFF00FF, "whitesmoke": 0xF5F5F5, "transparent": 0]
        if let hex = named[text] {
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                           alpha: text == "transparent" ? 0 : 1)
        }
        return nil
    }
}
