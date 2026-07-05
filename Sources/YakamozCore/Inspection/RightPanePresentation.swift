public enum RightPaneMode: Equatable, Sendable {
    case compose
    case inspect
}

public enum RightPaneComposeSection: Equatable, Sendable {
    case provider
    case workspace
    case tools
}

public enum RightPaneInspectTab: String, CaseIterable, Identifiable, Equatable, Sendable {
    case prompt
    case sent
    case journal
    case response
    case tools

    public var id: String {
        rawValue
    }
}

public struct RightPanePresentation: Equatable, Sendable {
    public let selectedInspectionTurnIndex: Int?

    public init(selectedInspectionTurnIndex: Int?) {
        self.selectedInspectionTurnIndex = selectedInspectionTurnIndex
    }

    public var mode: RightPaneMode {
        selectedInspectionTurnIndex == nil ? .compose : .inspect
    }

    public var composeSections: [RightPaneComposeSection] {
        [.provider, .workspace, .tools]
    }

    public var inspectTabs: [RightPaneInspectTab] {
        RightPaneInspectTab.allCases
    }
}
