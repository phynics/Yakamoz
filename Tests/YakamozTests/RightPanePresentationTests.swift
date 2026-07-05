import Testing
import YakamozCore

@Suite("RightPanePresentation")
struct RightPanePresentationTests {
    @Test("No selected turn presents compose mode with next-turn sections")
    func noSelectionPresentsComposeMode() {
        let presentation = RightPanePresentation(selectedInspectionTurnIndex: nil)

        #expect(presentation.mode == .compose)
        #expect(presentation.composeSections == [.provider, .workspace, .tools])
    }

    @Test("Selecting a turn presents inspect mode with only per-turn tabs")
    func selectionPresentsInspectMode() {
        let presentation = RightPanePresentation(selectedInspectionTurnIndex: 4)

        #expect(presentation.mode == .inspect)
        #expect(presentation.inspectTabs == [.prompt, .sent, .journal, .response, .tools])
    }
}
