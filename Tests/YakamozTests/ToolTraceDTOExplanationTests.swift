import Testing
@testable import YakamozCore

/// TEX-2 scope item 2: the inspector's `ToolTraceDTO` must expose the same
/// explanation-caption/filtered-arguments split as the transcript surface
/// (`ToolTranscriptPresentation`), backed by the shared `ToolCallExplanation` helper.
@Suite("ToolTraceDTO explanation")
struct ToolTraceDTOExplanationTests {
    @Test("explanationText extracts the explanation argument")
    func explanationTextExtracts() throws {
        let dto = ToolTraceDTO(
            id: "call_1",
            name: "calculator",
            status: .success,
            arguments: #"{"expression":"2 + 2","explanation":"Adding two numbers."}"#,
            output: "4"
        )

        #expect(dto.explanationText == "Adding two numbers.")
        #expect(try !(#require(dto.displayArguments?.contains("explanation"))))
        #expect(try #require(dto.displayArguments?.contains("expression")))
    }

    @Test("explanationText is nil when absent")
    func explanationTextNilWhenAbsent() {
        let dto = ToolTraceDTO(
            id: "call_2",
            name: "calculator",
            status: .success,
            arguments: #"{"expression":"2 + 2"}"#,
            output: "4"
        )

        #expect(dto.explanationText == nil)
        #expect(dto.displayArguments == dto.arguments)
    }

    @Test("displayArguments is nil when arguments are nil")
    func displayArgumentsNilWhenArgumentsNil() {
        let dto = ToolTraceDTO(id: "call_3", name: "current_datetime", status: .success)

        #expect(dto.explanationText == nil)
        #expect(dto.displayArguments == nil)
    }
}
