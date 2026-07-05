import Testing
import YakamozCore

@Suite("TranscriptRowPresentation")
struct TranscriptRowPresentationTests {
    @Test("User and assistant rows render full-width with role icons and gutter accents")
    func roleRowsUseGutterTranscriptStyle() {
        let user = TranscriptRowPresentation(role: .user, isSelected: false)
        let assistant = TranscriptRowPresentation(role: .assistant, isSelected: false)

        #expect(user.layout == .fullWidthLeading)
        #expect(assistant.layout == .fullWidthLeading)
        #expect(user.usesBubbleBackground == false)
        #expect(assistant.usesBubbleBackground == false)
        #expect(user.iconSystemName == "person.crop.circle")
        #expect(assistant.iconSystemName == "moon.stars")
        #expect(user.gutterAccent == .sea)
        #expect(assistant.gutterAccent == .moon)
    }

    @Test("Selected assistant rows keep the gutter style and add a subtle selection tint")
    func selectedAssistantUsesSubtleSelectionTreatment() {
        let selected = TranscriptRowPresentation(role: .assistant, isSelected: true)

        #expect(selected.layout == .fullWidthLeading)
        #expect(selected.usesBubbleBackground == false)
        #expect(selected.selectionTreatment == .subtleTint)
        #expect(selected.gutterAccent == .selectedMoon)
    }

    @Test("Error rows participate in the full-width transcript system")
    func errorRowsUseTranscriptStyling() {
        let error = TranscriptRowPresentation(role: .error, isSelected: false)

        #expect(error.layout == .fullWidthLeading)
        #expect(error.usesBubbleBackground == false)
        #expect(error.iconSystemName == "exclamationmark.triangle.fill")
        #expect(error.gutterAccent == .error)
    }

    @Test("Thinking rows join the transcript row system with their own reverie accent")
    func thinkingRowsUseTranscriptStyling() {
        let thinking = TranscriptRowPresentation(role: .thinking, isSelected: false)

        #expect(thinking.layout == .fullWidthLeading)
        #expect(thinking.usesBubbleBackground == false)
        #expect(thinking.iconSystemName == "brain.head.profile")
        #expect(thinking.gutterAccent == .reverie)
        #expect(thinking.gutterAccent != TranscriptRowPresentation(role: .assistant, isSelected: false).gutterAccent)
    }
}
