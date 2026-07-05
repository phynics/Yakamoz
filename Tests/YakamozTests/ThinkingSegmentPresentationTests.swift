import Foundation
import Testing
@testable import YakamozCore

/// UIX-13: `ThinkingSegmentPresentation` no longer decides which slice of text to show
/// inline (UIX-11's head/tail character-count slicing is gone — the live tail is now a
/// purely visual, fixed-height/gradient-masked crop built in SwiftUI layout) or whether a
/// popover affordance is warranted (UIX-9/UIX-11's `needsPopover` gate is gone — every
/// thinking row now offers the popover). It only carries `fullText` (for the popover) and
/// `isStreaming` (which still drives the tail-vs-marker row state).
@Suite("ThinkingSegmentPresentation (UIX-13)")
struct ThinkingSegmentPresentationTests {
    @Test("fullText exposes the untruncated thought")
    func fullTextExposesUntruncatedThought() {
        let text = String(repeating: "x", count: 1000)
        let presentation = ThinkingSegmentPresentation(thought: text, isStreaming: false)

        #expect(presentation.fullText == text)
    }

    @Test("isStreaming reflects the segment's streaming state")
    func isStreamingReflectsState() {
        #expect(ThinkingSegmentPresentation(thought: "thinking...", isStreaming: true).isStreaming == true)
        #expect(ThinkingSegmentPresentation(thought: "done.", isStreaming: false).isStreaming == false)
    }

    @Test("Short and long text both round-trip through fullText unchanged")
    func shortAndLongTextRoundTrip() {
        let short = "Let me think about this."
        #expect(ThinkingSegmentPresentation(thought: short, isStreaming: false).fullText == short)

        let long = String(repeating: "a", count: 100) + String(repeating: "b", count: 500)
        #expect(ThinkingSegmentPresentation(thought: long, isStreaming: true).fullText == long)
    }

    @Test("Empty thought text is a valid, distinct presentation")
    func emptyThoughtIsValid() {
        let presentation = ThinkingSegmentPresentation(thought: "", isStreaming: true)
        #expect(presentation.fullText == "")
        #expect(presentation.isStreaming == true)
    }

    @Test("Equatable conformance compares both fullText and isStreaming")
    func equatableComparesBothFields() {
        let a = ThinkingSegmentPresentation(thought: "same text", isStreaming: true)
        let b = ThinkingSegmentPresentation(thought: "same text", isStreaming: true)
        let c = ThinkingSegmentPresentation(thought: "same text", isStreaming: false)
        let d = ThinkingSegmentPresentation(thought: "different text", isStreaming: true)

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}
