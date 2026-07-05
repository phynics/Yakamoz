public enum RightPaneMode: Equatable, Sendable {
    case compose
    case inspect
}

/// Presentation-level contract for the inspector drawer's Compose/Inspect mode switch
/// (UIX-3). The only thing `InspectorDrawer` actually consumes from this type is `mode` —
/// it renders its own `InspectorTab` enum and hard-coded compose sections, which live in
/// the app target (`Sources/Yakamoz`) and would duplicate `RightPaneInspectTab`/
/// `RightPaneComposeSection` for no consumer. Kept minimal on purpose (UIX-3 review fix #4):
/// trimmed to just the derived `mode`, rather than carrying app-owned tab/section lists
/// that nothing reads.
public struct RightPanePresentation: Equatable, Sendable {
    public let selectedInspectionTurnIndex: Int?

    public init(selectedInspectionTurnIndex: Int?) {
        self.selectedInspectionTurnIndex = selectedInspectionTurnIndex
    }

    public var mode: RightPaneMode {
        selectedInspectionTurnIndex == nil ? .compose : .inspect
    }
}
