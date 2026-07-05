import Foundation

/// Pure decision logic for the transcript's "follow new content only while pinned to the
/// bottom" behavior (UIX-8). `ChatView` owns the actual scroll-position observation
/// (`onScrollGeometryChange`) and the `ScrollViewReader`/overlay wiring; this type only
/// answers "given this input, should we scroll, and should the jump-to-bottom button show?"
/// so the decision itself is unit-testable without SwiftUI.
public enum ScrollFollowPresentation {
    /// Whether a newly-appended transcript item (a new assistant turn, error row, or
    /// prompt row) should trigger an autoscroll to it.
    ///
    /// Content events never force pinning — only an explicit user action (sending a
    /// message) does that, handled separately by `ChatView` snapping to bottom on send.
    /// A new item scrolls the view only when the user is already pinned to the bottom;
    /// otherwise their scroll position is left alone.
    public static func shouldFollowNewItem(isPinnedToBottom: Bool) -> Bool {
        isPinnedToBottom
    }

    /// Whether growing content within the last (still-streaming) assistant turn should
    /// keep the view following it. Only true while pinned and the turn is still
    /// streaming — mirrors `shouldFollowNewItem`'s pinned-only guard.
    public static func shouldFollowStreamingGrowth(isPinnedToBottom: Bool, isLastTurnStreaming: Bool) -> Bool {
        isPinnedToBottom && isLastTurnStreaming
    }

    /// Whether the floating jump-to-bottom affordance should be visible: exactly when
    /// the user is not pinned to the bottom. Hidden while pinned (there's nowhere to
    /// "jump" to that they aren't already at).
    public static func shouldShowJumpToBottomButton(isPinnedToBottom: Bool) -> Bool {
        !isPinnedToBottom
    }

    /// A single, order-sensitive metric of how much a turn's *content* has grown, used to
    /// detect streaming progress even during thinking-only or tool-only stretches where
    /// `reconstructedText` alone would stall (UIX-7 broadened this beyond plain text
    /// length). Combines reconstructed-text length, thinking length, and segment count so
    /// growth in any of those dimensions changes the metric and re-triggers the
    /// mid-stream follow `onChange` handler.
    public static func streamingGrowthMetric(
        reconstructedTextCount: Int,
        thinkingCount: Int,
        segmentCount: Int
    ) -> Int {
        reconstructedTextCount + thinkingCount + segmentCount
    }

    /// UIX-14: whether an `onScrollGeometryChange` distance-to-bottom reading should be
    /// allowed to *unpin* (flip `isStickyToBottom` from `true` to `false`).
    ///
    /// Root cause of the UIX-14 intermittent drop-out: a plain "distance <= 80pt" check
    /// can't distinguish "the user scrolled up" from "content grew (or a programmatic
    /// `scrollTo` landed short on a mid-layout item) after the last scroll-to-bottom,
    /// pushing the bottom edge away." Both produce the same symptom — distance exceeds
    /// the threshold — but only the first should unpin. This only fires with `false`
    /// (never unpin) while a programmatic scroll initiated by the follow logic itself is
    /// still "in flight" (see `ChatView`'s `pendingProgrammaticScrollCount`) — i.e.
    /// evidence of *user* scrolling is required to unpin, not just distance. Re-pinning
    /// (`isAtBottom == true`) is always allowed regardless of this flag: snapping back
    /// into the sticky zone is never something we need to suppress.
    public static func shouldUnpin(isAtBottom: Bool, isProgrammaticScrollInFlight: Bool) -> Bool {
        guard !isAtBottom else { return false }
        return !isProgrammaticScrollInFlight
    }
}
