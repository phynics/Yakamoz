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
