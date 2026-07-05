import Foundation
import Testing
@testable import YakamozCore

@Suite("TruncatedTextPresentation (UIX-6)")
struct TruncatedTextPresentationTests {
    @Test func shortMessagePassesThroughUntruncated() {
        let text = "hello world"
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.isTruncatable == false)
        #expect(presentation.collapsedText == text)
        #expect(presentation.displayedText(isExpanded: false) == text)
        #expect(presentation.displayedText(isExpanded: true) == text)
    }

    @Test func textExactlyAtThresholdIsNotTruncatable() {
        let text = String(repeating: "a", count: 2000)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.isTruncatable == false)
        #expect(presentation.collapsedText == text)
    }

    @Test func textOverThresholdIsTruncatedWhenCollapsed() {
        let text = String(repeating: "a", count: 2500)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.isTruncatable == true)
        #expect(presentation.collapsedText.count == 2000)
        #expect(presentation.displayedText(isExpanded: false).count == 2000)
    }

    @Test func expandingRevealsFullText() {
        let text = String(repeating: "b", count: 5000)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.displayedText(isExpanded: true) == text)
        #expect(presentation.displayedText(isExpanded: true).count == 5000)
    }

    @Test func characterCountReflectsFullTextLength() {
        let text = String(repeating: "c", count: 12345)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.characterCount == 12345)
    }

    @Test func expanderLabelIncludesFormattedCharacterCount() {
        let text = String(repeating: "d", count: 12345)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.expanderLabel == "Show all 12,345 characters")
    }

    @Test func expanderLabelForSmallCountHasNoGrouping() {
        let text = String(repeating: "e", count: 42)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 10)

        #expect(presentation.expanderLabel == "Show all 42 characters")
    }

    @Test func defaultThresholdMatchesTicketSpec() {
        #expect(TruncatedTextPresentation.defaultThreshold == 2000)
    }

    @Test func emptyTextIsNotTruncatable() {
        let presentation = TruncatedTextPresentation(fullText: "", threshold: 2000)

        #expect(presentation.isTruncatable == false)
        #expect(presentation.collapsedText.isEmpty)
        #expect(presentation.characterCount == 0)
    }

    // MARK: - UIX-11: tail mode (for streaming content, e.g. live reasoning traces)

    @Test func collapsedTailTextReturnsFullTextWhenNotTruncatable() {
        let text = "hello world"
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 2000)

        #expect(presentation.collapsedTailText == text)
    }

    @Test func collapsedTailTextReturnsLastThresholdCharactersWhenTruncatable() {
        let text = String(repeating: "a", count: 200) + String(repeating: "b", count: 200)
        let presentation = TruncatedTextPresentation(fullText: text, threshold: 200)

        #expect(presentation.collapsedTailText == String(repeating: "b", count: 200))
        #expect(presentation.collapsedTailText.count == 200)
    }
}
