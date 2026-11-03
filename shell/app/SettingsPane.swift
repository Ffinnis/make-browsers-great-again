import Foundation

enum SettingsPane: Int, CaseIterable {
    case general, privacy, passwords, developer, agents

    var title: String {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .passwords: "Passwords"
        case .developer: "Developer"
        case .agents: "Agents"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .passwords: "key"
        case .developer: "hammer"
        case .agents: "sparkles"
        }
    }
}
