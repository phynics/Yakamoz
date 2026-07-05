import Testing
import YakamozCore

@Suite("RightPanePresentation")
struct RightPanePresentationTests {
    @Test("No selected turn presents compose mode")
    func noSelectionPresentsComposeMode() {
        let presentation = RightPanePresentation(selectedInspectionTurnIndex: nil)

        #expect(presentation.mode == .compose)
    }

    @Test("Selecting a turn presents inspect mode")
    func selectionPresentsInspectMode() {
        let presentation = RightPanePresentation(selectedInspectionTurnIndex: 4)

        #expect(presentation.mode == .inspect)
    }
}
