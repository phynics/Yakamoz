import Foundation

/// UIX-13: presentation-level projection for a single thinking/reasoning segment row.
///
/// Superseded design: UIX-9's auto-expand/auto-collapse `DisclosureGroup` (with its
/// `manualExpansion` override) and UIX-11's character-count head/tail slicing
/// (`inlinePreview`, `needsPopover` gate) are both gone. The row no longer discloses at
/// all — while streaming it shows a fixed-height, bottom-anchored, gradient-masked tail
/// (a *visual* line-based crop built in SwiftUI layout, not a string slice) and once the
/// segment finishes it collapses to a compact one-line marker. The only text-shaping
/// decision left at this layer is "should the tail area render at all" — that's exactly
/// `isStreaming`, which the row already receives directly, so this type only exists now
/// to hold `fullText` for the popover. Kept as a struct (rather than inlining `String`
/// directly) so the row and popover keep one shared vocabulary and future presentation
/// logic (e.g. a line-count estimate for the mask height) has an obvious home.
public struct ThinkingSegmentPresentation: Equatable, Sendable {
    /// The full, untruncated reasoning text — used by the popover and the live tail
    /// (which crops visually via a fixed-height container, not by slicing this string).
    public let fullText: String
    /// Whether this segment is the turn's actively-streaming trailing segment. Drives
    /// both the fixed-height masked tail (only rendered while streaming) and the
    /// eventual collapse to a compact marker row once streaming ends.
    public let isStreaming: Bool

    public init(thought: String, isStreaming: Bool) {
        fullText = thought
        self.isStreaming = isStreaming
    }
}
