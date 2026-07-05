import Foundation
import Testing
@testable import YakamozCore

/// UIX-11: presentation-level decisions for the inline expanded thinking disclosure —
/// which slice of the reasoning text to show inline (capped preview; the live tail while
/// streaming, the head once complete) and when a popover affordance for the full text is
/// warranted (only once the text exceeds the cap).
@Suite("ThinkingSegmentPresentation (UIX-11)")
struct ThinkingSegmentPresentationTests {
    @Test("Short thinking text needs no popover affordance and renders in full")
    func shortTextNeedsNoPopover() {
        let presentation = ThinkingSegmentPresentation(thought: "Let me think about this.", isStreaming: false)

        #expect(presentation.needsPopover == false)
        #expect(presentation.inlinePreview == "Let me think about this.")
    }

    @Test("Complete thinking over the cap shows the head as the inline preview and needs a popover")
    func completeTextOverCapShowsHeadPreview() {
        let text = String(repeating: "a", count: 100) + String(repeating: "b", count: 500)
        let presentation = ThinkingSegmentPresentation(thought: text, isStreaming: false, threshold: 300)

        #expect(presentation.needsPopover == true)
        #expect(presentation.inlinePreview == String(repeating: "a", count: 100) + String(repeating: "b", count: 200))
        #expect(presentation.inlinePreview.count == 300)
    }

    @Test("Streaming thinking over the cap shows the live tail as the inline preview")
    func streamingTextOverCapShowsTailPreview() {
        let text = String(repeating: "a", count: 500) + String(repeating: "b", count: 100)
        let presentation = ThinkingSegmentPresentation(thought: text, isStreaming: true, threshold: 300)

        #expect(presentation.needsPopover == true)
        #expect(presentation.inlinePreview == String(repeating: "a", count: 200) + String(repeating: "b", count: 100))
        #expect(presentation.inlinePreview.count == 300)
    }

    @Test("Streaming thinking under the cap shows the full text and needs no popover")
    func streamingTextUnderCapShowsFullText() {
        let text = "Considering the approach..."
        let presentation = ThinkingSegmentPresentation(thought: text, isStreaming: true, threshold: 300)

        #expect(presentation.needsPopover == false)
        #expect(presentation.inlinePreview == text)
    }

    @Test("Default threshold is a few hundred characters, suited to a transcript-inline preview")
    func defaultThresholdMatchesTicketSpec() {
        #expect(ThinkingSegmentPresentation.defaultThreshold == 300)
    }

    @Test("fullText exposes the untruncated thought for the popover")
    func fullTextExposesUntruncatedThought() {
        let text = String(repeating: "x", count: 1000)
        let presentation = ThinkingSegmentPresentation(thought: text, isStreaming: false, threshold: 300)

        #expect(presentation.fullText == text)
    }
}
