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
}
