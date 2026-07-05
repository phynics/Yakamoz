public enum TranscriptRowRole: Equatable, Sendable {
    case user
    case assistant
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

    public var layout: TranscriptRowLayout { .fullWidthLeading }
    public var usesBubbleBackground: Bool { false }

    public var iconSystemName: String {
        switch role {
        case .user:
            "person.crop.circle"
        case .assistant:
            "moon.stars"
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
