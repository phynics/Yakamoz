import Testing
import YakamozCore

@Suite("ToolTranscriptPresentation")
struct ToolTranscriptPresentationTests {
    @Test("Formats a succeeded tool call with fx notation")
    func formatsSucceededToolCall() {
        let trace = ToolTrace(
            id: "call_1",
            name: "calculator",
            state: .succeeded,
            arguments: #"{"expression":"2 + 2"}"#,
            output: "4"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.notation == "calculator(expression: 2 + 2) -> 4")
        #expect(presentation.status == .success)
        #expect(presentation.detailTitle == "calculator")
    }

    @Test("Formats failed calls using the error as the result summary")
    func formatsFailedToolCall() {
        let trace = ToolTrace(
            id: "call_2",
            name: "read_file",
            state: .failed,
            arguments: #"{"path":"/secret"}"#,
            error: "permission denied"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.notation == "read_file(path: /secret) -> permission denied")
        #expect(presentation.status == .failure)
        #expect(presentation.fullResponse == "permission denied")
    }

    @Test("Excludes explanation from the fx-notation argument list and full parameters, exposing it as a caption")
    func excludesExplanationFromNotationAndParameters() {
        let trace = ToolTrace(
            id: "call_4",
            name: "calculator",
            state: .succeeded,
            arguments: #"{"expression":"2 + 2","explanation":"Adding two numbers to answer the question."}"#,
            output: "4"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.notation == "calculator(expression: 2 + 2) -> 4")
        #expect(presentation.explanationText == "Adding two numbers to answer the question.")
        #expect(!presentation.fullParameters.contains("explanation"))
        #expect(presentation.fullParameters.contains("expression"))
    }

    @Test("explanationText is nil when the call has no explanation argument")
    func explanationTextNilWhenAbsent() {
        let trace = ToolTrace(
            id: "call_5",
            name: "calculator",
            state: .succeeded,
            arguments: #"{"expression":"2 + 2"}"#,
            output: "4"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.explanationText == nil)
        #expect(presentation.notation == "calculator(expression: 2 + 2) -> 4")
    }

    @Test("explanationText surfaces live while the trace is still attempting")
    func explanationTextSurfacesLiveWhileAttempting() {
        let trace = ToolTrace(
            id: "call_6",
            name: "search",
            state: .attempting,
            arguments: #"{"query":"moon","explanation":"Looking up moon facts."}"#
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.status == .attempting)
        #expect(presentation.explanationText == "Looking up moon facts.")
    }

    @Test("Truncates long parameter values and result summaries in the collapsed row")
    func truncatesCollapsedValues() {
        let trace = ToolTrace(
            id: "call_3",
            name: "terminal_run",
            state: .succeeded,
            arguments: #"{"command":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
            output: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.notation == "terminal_run(command: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...) -> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb...")
    }

    // MARK: - UIX-10: chat row title (explanation-or-name fallback)

    @Test("UIX-10: rowTitle is the explanation when present")
    func rowTitleUsesExplanationWhenPresent() {
        let trace = ToolTrace(
            id: "call_7",
            name: "calculator",
            state: .succeeded,
            arguments: #"{"expression":"2 + 2","explanation":"Adding two numbers."}"#,
            output: "4"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.rowTitle == "Adding two numbers.")
        #expect(presentation.rowTitleIsFallbackName == false)
    }

    @Test("UIX-10: rowTitle falls back to the bare tool name when explanation is absent")
    func rowTitleFallsBackToNameWhenExplanationAbsent() {
        let trace = ToolTrace(
            id: "call_8",
            name: "cat",
            state: .succeeded,
            arguments: #"{"path":"/tmp/foo"}"#,
            output: "contents"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.rowTitle == "cat")
        #expect(presentation.rowTitleIsFallbackName == true)
    }

    @Test("UIX-10: rowTitle falls back to the bare tool name when explanation is blank")
    func rowTitleFallsBackToNameWhenExplanationBlank() {
        let trace = ToolTrace(
            id: "call_9",
            name: "cat",
            state: .succeeded,
            arguments: #"{"path":"/tmp/foo","explanation":"   "}"#,
            output: "contents"
        )

        let presentation = ToolTranscriptPresentation(trace: trace)

        #expect(presentation.rowTitle == "cat")
        #expect(presentation.rowTitleIsFallbackName == true)
    }
}

@Suite("TurnTranscriptProjection")
struct TurnTranscriptProjectionTests {
    @Test("Returns nil when the turn has no recorded segments (reload/no-history fallback)")
    func returnsNilWhenNoSegments() {
        let turn = ChatTurnState(turnIndex: 0)

        #expect(TurnTranscriptProjection.segments(for: turn) == nil)
    }

    @Test("Projects text and tool segments in chronological order")
    func projectsSegmentsInOrder() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [
            .text("Let me check that."),
            .tool(id: "call-1"),
            .text("Found it."),
        ]
        turn.toolOrder = ["call-1"]
        turn.tools = ["call-1": ToolTrace(id: "call-1", name: "search", state: .succeeded, output: "3 results")]

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments?.count == 3)
        #expect(segments?[0] == .text("Let me check that."))
        #expect(segments?[1] == .tool(ToolTrace(id: "call-1", name: "search", state: .succeeded, output: "3 results")))
        #expect(segments?[2] == .text("Found it."))
    }

    @Test("Drops a tool segment whose id has no matching trace")
    func dropsUnresolvedToolSegment() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [.text("Hi"), .tool(id: "missing")]

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [.text("Hi")])
    }

    @Test("UIX-7: projects thinking segments in chronological order alongside text and tool segments")
    func projectsThinkingSegmentsInOrder() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [
            .thinking("Let me think."),
            .text("Checking now."),
            .tool(id: "call-1"),
            .thinking("Considering the result."),
            .text("Here's the answer."),
        ]
        turn.toolOrder = ["call-1"]
        turn.tools = ["call-1": ToolTrace(id: "call-1", name: "search", state: .succeeded, output: "3 results")]

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [
            .thinking("Let me think.", isStreaming: false),
            .text("Checking now."),
            .tool(ToolTrace(id: "call-1", name: "search", state: .succeeded, output: "3 results")),
            .thinking("Considering the result.", isStreaming: false),
            .text("Here's the answer."),
        ])
    }

    @Test("UIX-7: drops an empty thinking segment")
    func dropsEmptyThinkingSegment() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [.thinking(""), .text("Hi")]

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [.text("Hi")])
    }

    @Test("UIX-9: a trailing thinking segment on an incomplete turn is streaming")
    func trailingThinkingSegmentOnIncompleteTurnIsStreaming() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [.text("Checking now."), .thinking("Considering...")]
        turn.isComplete = false

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [.text("Checking now."), .thinking("Considering...", isStreaming: true)])
    }

    @Test("UIX-9: a trailing thinking segment on a completed turn is not streaming")
    func trailingThinkingSegmentOnCompletedTurnIsNotStreaming() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [.text("Checking now."), .thinking("Considering...")]
        turn.isComplete = true

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [.text("Checking now."), .thinking("Considering...", isStreaming: false)])
    }

    @Test("UIX-9: an earlier thinking segment is not streaming even while the turn is still in progress, once content follows it")
    func earlierThinkingSegmentIsNotStreamingOnceFollowedByContent() {
        var turn = ChatTurnState(turnIndex: 0)
        turn.turnSegments = [
            .thinking("First thought."),
            .text("Some text."),
            .thinking("Second thought, still streaming."),
        ]
        turn.isComplete = false

        let segments = TurnTranscriptProjection.segments(for: turn)

        #expect(segments == [
            .thinking("First thought.", isStreaming: false),
            .text("Some text."),
            .thinking("Second thought, still streaming.", isStreaming: true),
        ])
    }

    // MARK: - UIX-17: indexedSegments provides stable original-index IDs

    @Test("UIX-17: indexedSegments carries the original turnSegments index as a stable id")
    func indexedSegmentsCarriesOriginalIndex() {
        var turn = ChatTurnState(turnIndex: 0)
        // turnSegments: [empty-text(filtered), text, tool(missing trace, filtered), text]
        // → indexedSegments should return [(1, .text), (3, .text)] — indices 0 and 2
        // are filtered out, but the remaining entries keep their original indices.
        turn.turnSegments = [
            .text(""),
            .text("Hello"),
            .tool(id: "missing"),
            .text("World"),
        ]

        let indexed = TurnTranscriptProjection.indexedSegments(for: turn)

        #expect(indexed?.count == 2)
        #expect(indexed?[0].index == 1)
        #expect(indexed?[0].segment == .text("Hello"))
        #expect(indexed?[1].index == 3)
        #expect(indexed?[1].segment == .text("World"))
    }

    @Test("UIX-17: indexedSegments returns nil when turnSegments is empty (mirrors segments)")
    func indexedSegmentsReturnsNilWhenEmpty() {
        let turn = ChatTurnState(turnIndex: 0)

        #expect(TurnTranscriptProjection.indexedSegments(for: turn) == nil)
    }

    @Test("UIX-17: indexedSegments preserves original indices across filtering (stable ForEach ids)")
    func indexedSegmentsIndicesAreStableAcrossFiltering() {
        // Simulate the streaming transition that crashed with id: \.offset:
        // a previously-empty thinking segment (filtered out, index 0) receives text,
        // appearing in the filtered array and shifting subsequent offsets.
        var before = ChatTurnState(turnIndex: 0)
        before.turnSegments = [.thinking(""), .text("Hello")]
        var after = ChatTurnState(turnIndex: 0)
        after.turnSegments = [.thinking("Hmm"), .text("Hello")]

        let beforeIndexed = TurnTranscriptProjection.indexedSegments(for: before)
        let afterIndexed = TurnTranscriptProjection.indexedSegments(for: after)

        // Before: only the text segment (original index 1) is present.
        #expect(beforeIndexed?.count == 1)
        #expect(beforeIndexed?[0].index == 1)

        // After: thinking (original index 0) appears, but the text segment at index 1
        // keeps the SAME id — no offset shift, no view-type mismatch crash.
        #expect(afterIndexed?.count == 2)
        #expect(afterIndexed?[0].index == 0)
        #expect(afterIndexed?[1].index == 1)
    }
}
