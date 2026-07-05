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
}
