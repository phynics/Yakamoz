import Foundation
import Testing
@testable import YakamozCore

/// Exercises the shared TEX-2 helper (`ToolCallExplanation`) that both the transcript
/// (`ToolTranscriptPresentation`) and the inspector (`ToolTraceDTO`) rely on to surface a
/// tool call's model-authored `explanation` argument as presentation, and to keep it out
/// of any raw-argument listing.
@Suite("ToolCallExplanation")
struct ToolCallExplanationTests {
    @Test("explanationText extracts the explanation string from a JSON arguments blob")
    func extractsExplanation() {
        let arguments = #"{"expression":"2 + 2","explanation":"Adding two numbers to answer the question."}"#

        #expect(ToolCallExplanation.explanationText(fromArguments: arguments) == "Adding two numbers to answer the question.")
    }

    @Test("explanationText is nil when arguments are nil")
    func nilWhenArgumentsNil() {
        #expect(ToolCallExplanation.explanationText(fromArguments: nil) == nil)
    }

    @Test("explanationText is nil when explanation key is absent")
    func nilWhenAbsent() {
        let arguments = #"{"expression":"2 + 2"}"#

        #expect(ToolCallExplanation.explanationText(fromArguments: arguments) == nil)
    }

    @Test("explanationText is nil when explanation is blank")
    func nilWhenBlank() {
        let arguments = #"{"expression":"2 + 2","explanation":"   "}"#

        #expect(ToolCallExplanation.explanationText(fromArguments: arguments) == nil)
    }

    @Test("explanationText is nil when explanation is a non-string value")
    func nilWhenNonString() {
        let arguments = #"{"expression":"2 + 2","explanation":42}"#

        #expect(ToolCallExplanation.explanationText(fromArguments: arguments) == nil)
    }

    @Test("explanationText tolerates unparseable partial JSON during streaming, returning nil")
    func nilWhenUnparseablePartialJSON() {
        // Mid-stream, arguments arrive as a partial/truncated JSON chunk.
        let partial = #"{"expression":"2 + 2","explanation":"Addi"#

        #expect(ToolCallExplanation.explanationText(fromArguments: partial) == nil)
    }

    @Test("displayArguments drops only the explanation key")
    func displayArgumentsDropsExplanation() {
        let arguments = #"{"expression":"2 + 2","explanation":"Adding two numbers."}"#

        let display = ToolCallExplanation.displayArguments(fromArguments: arguments)

        #expect(display?.contains("explanation") == false)
        #expect(display?.contains("expression") == true)
    }

    @Test("displayArguments returns the original string unchanged when there is no explanation key")
    func displayArgumentsUnchangedWithoutExplanation() {
        let arguments = #"{"expression":"2 + 2"}"#

        #expect(ToolCallExplanation.displayArguments(fromArguments: arguments) == arguments)
    }

    @Test("displayArguments returns nil when arguments are nil")
    func displayArgumentsNilWhenArgumentsNil() {
        #expect(ToolCallExplanation.displayArguments(fromArguments: nil) == nil)
    }

    @Test("displayArguments tolerates unparseable partial JSON, returning the original string")
    func displayArgumentsUnparseablePartialJSON() {
        let partial = #"{"expression":"2 + 2","explanation":"Addi"#

        #expect(ToolCallExplanation.displayArguments(fromArguments: partial) == partial)
    }

    @Test("composeSystemInstructions appends prompt guidance when tools are offered")
    func composeSystemInstructionsAppendsGuidanceWithTools() {
        let composed = ToolCallExplanation.composeSystemInstructions(base: "Be concise.", hasTools: true)

        #expect(composed?.contains("Be concise.") == true)
        #expect(composed?.contains(ToolCallExplanation.promptGuidance) == true)
    }

    @Test("composeSystemInstructions returns base unchanged when no tools are offered")
    func composeSystemInstructionsUnchangedWithoutTools() {
        #expect(ToolCallExplanation.composeSystemInstructions(base: "Be concise.", hasTools: false) == "Be concise.")
        #expect(ToolCallExplanation.composeSystemInstructions(base: nil, hasTools: false) == nil)
    }

    @Test("composeSystemInstructions returns just the guidance when base is nil and tools are offered")
    func composeSystemInstructionsGuidanceOnlyWhenBaseNil() {
        #expect(ToolCallExplanation.composeSystemInstructions(base: nil, hasTools: true) == ToolCallExplanation.promptGuidance)
    }
}
