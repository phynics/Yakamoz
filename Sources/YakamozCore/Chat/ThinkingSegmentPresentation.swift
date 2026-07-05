import Foundation

/// UIX-11: presentation-level projection for a single expanded thinking/reasoning
/// disclosure row. Wraps `TruncatedTextPresentation` to decide which slice of a
/// potentially-huge reasoning trace to show inline, and whether a popover affordance for
/// the full text is warranted — mirroring the tool-row pattern (UIX-2/UIX-10) where the
/// mechanical/verbose detail moves out of the compact transcript row and into a popover.
public struct ThinkingSegmentPresentation: Equatable, Sendable {
    /// Cap on the inline preview, in characters. Picked to be "a few hundred
    /// characters" per the UIX-11 design direction — enough to read a couple of
    /// sentences of live reasoning at a glance without the disclosure growing into a
    /// second scrollable region competing with the popover. Distinct from (and much
    /// smaller than) `TruncatedTextPresentation.defaultThreshold` (2000), which caps a
    /// full sent-message body rather than a transcript preview line.
    public static let defaultThreshold = 300

    private let truncation: TruncatedTextPresentation
    /// Whether this segment is the turn's actively-streaming trailing segment (UIX-9).
    public let isStreaming: Bool

    public init(thought: String, isStreaming: Bool, threshold: Int = ThinkingSegmentPresentation.defaultThreshold) {
        truncation = TruncatedTextPresentation(fullText: thought, threshold: threshold)
        self.isStreaming = isStreaming
    }

    /// The full, untruncated reasoning text — used by the popover and for copy/paste.
    public var fullText: String {
        truncation.fullText
    }

    /// Whether the text exceeds the cap and thus needs a popover affordance to reach the
    /// full content. Short thinking (at or under the cap) shows no popover affordance at
    /// all — it already renders in full inline.
    public var needsPopover: Bool {
        truncation.isTruncatable
    }

    /// The text to render inline in the expanded disclosure: the full text when it's
    /// short enough, otherwise a capped slice. While streaming, the slice is the *tail*
    /// (most recently produced reasoning) so the live view stays informative as new
    /// tokens arrive; once the segment is no longer streaming, the slice is the *head*
    /// (matching the conventional "read from the start" expectation for finished text).
    public var inlinePreview: String {
        if !needsPopover { return fullText }
        return isStreaming ? truncation.collapsedTailText : truncation.collapsedText
    }
}
