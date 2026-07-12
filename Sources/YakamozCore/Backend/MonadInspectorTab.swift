import Foundation

public enum MonadInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case response
    case tools
    case prompt
    case sent
    case journal

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .response: "Response"
        case .tools: "Tools"
        case .prompt: "Prompt"
        case .sent: "Sent"
        case .journal: "Journal"
        }
    }

    public var systemImage: String {
        switch self {
        case .response: "bubble.left.and.bubble.right"
        case .tools: "wrench.and.screwdriver"
        case .prompt: "text.alignleft"
        case .sent: "paperplane"
        case .journal: "book.closed"
        }
    }

    public var availableInMonad: Bool {
        switch self {
        case .response, .tools: true
        case .prompt, .sent, .journal: false
        }
    }
}
