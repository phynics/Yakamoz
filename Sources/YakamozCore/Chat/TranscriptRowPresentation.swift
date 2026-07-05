public enum TranscriptRowRole: Equatable, Sendable {
    case user
    case assistant
    case thinking
    case tool
    case error
    case prompt
}

public enum TranscriptRowLayout: Equatable, Sendable {
    case fullWidthLeading
}

public enum TranscriptGutterAccent: Equatable, Sendable {
    case sea
    case moon
    case selectedMoon
    /// Reasoning/thinking rows (UIX-7). Carries the deep indigo/purple that `moon` mapped
    /// to pre-recolor, now that assistant (`moon`) rows read turquoise (user direction
    /// 2026-07-05).
    case reverie
    case tool
    case error
    case neutral
}

public enum TranscriptSelectionTreatment: Equatable, Sendable {
    case none
    case subtleTint
}

public struct TranscriptRowPresentation: Equatable, Sendable {
    public let role: TranscriptRowRole
    public let isSelected: Bool

    public init(role: TranscriptRowRole, isSelected: Bool) {
        self.role = role
        self.isSelected = isSelected
    }

    public var layout: TranscriptRowLayout {
        .fullWidthLeading
    }

    public var usesBubbleBackground: Bool {
        false
    }

    public var iconSystemName: String {
        switch role {
        case .user:
            "person.crop.circle"
        case .assistant:
            "moon.stars"
        case .thinking:
            "brain.head.profile"
        case .tool:
            "function"
        case .error:
            "exclamationmark.triangle.fill"
        case .prompt:
            "questionmark.circle"
        }
    }

    public var gutterAccent: TranscriptGutterAccent {
        switch role {
        case .user:
            .sea
        case .assistant:
            isSelected ? .selectedMoon : .moon
        case .thinking:
            .reverie
        case .tool:
            .tool
        case .error:
            .error
        case .prompt:
            .neutral
        }
    }

    public var selectionTreatment: TranscriptSelectionTreatment {
        isSelected ? .subtleTint : .none
    }
}
