import Testing
import YakamozCore

@Suite("ScrollFollowPresentation")
struct ScrollFollowPresentationTests {
    @Test("A new transcript item only autoscrolls when already pinned to the bottom")
    func newItemFollowsOnlyWhenPinned() {
        #expect(ScrollFollowPresentation.shouldFollowNewItem(isPinnedToBottom: true) == true)
        #expect(ScrollFollowPresentation.shouldFollowNewItem(isPinnedToBottom: false) == false)
    }

    @Test("Mid-stream growth follows only when pinned AND the last turn is still streaming")
    func streamingGrowthFollowsOnlyWhenPinnedAndStreaming() {
        #expect(ScrollFollowPresentation.shouldFollowStreamingGrowth(isPinnedToBottom: true, isLastTurnStreaming: true) == true)
        #expect(ScrollFollowPresentation.shouldFollowStreamingGrowth(isPinnedToBottom: true, isLastTurnStreaming: false) == false)
        #expect(ScrollFollowPresentation.shouldFollowStreamingGrowth(isPinnedToBottom: false, isLastTurnStreaming: true) == false)
        #expect(ScrollFollowPresentation.shouldFollowStreamingGrowth(isPinnedToBottom: false, isLastTurnStreaming: false) == false)
    }

    @Test("The jump-to-bottom button shows exactly when not pinned")
    func jumpToBottomButtonVisibleOnlyWhenUnpinned() {
        #expect(ScrollFollowPresentation.shouldShowJumpToBottomButton(isPinnedToBottom: true) == false)
        #expect(ScrollFollowPresentation.shouldShowJumpToBottomButton(isPinnedToBottom: false) == true)
    }

    @Test("Streaming growth metric increases when reconstructed text grows")
    func growthMetricIncreasesWithText() {
        let before = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 0, segmentCount: 1)
        let after = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 15, thinkingCount: 0, segmentCount: 1)
        #expect(after > before)
    }

    @Test("Streaming growth metric increases during a thinking-only stretch (no text growth)")
    func growthMetricIncreasesWithThinkingOnly() {
        let before = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 5, segmentCount: 1)
        let after = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 20, segmentCount: 1)
        #expect(after > before)
    }

    @Test("Streaming growth metric increases during a tool-only stretch (new segment appended, no text/thinking growth)")
    func growthMetricIncreasesWithNewSegmentOnly() {
        let before = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 5, segmentCount: 2)
        let after = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 5, segmentCount: 3)
        #expect(after > before)
    }

    @Test("Streaming growth metric is stable (no false-positive growth) when nothing changed")
    func growthMetricStableWhenUnchanged() {
        let first = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 5, segmentCount: 2)
        let second = ScrollFollowPresentation.streamingGrowthMetric(reconstructedTextCount: 10, thinkingCount: 5, segmentCount: 2)
        #expect(first == second)
    }
}
