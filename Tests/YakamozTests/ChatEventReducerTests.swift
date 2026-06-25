import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("ChatEventReducer")
struct ChatEventReducerTests {
    private let clock = ContinuousClock()

    @Test("Generation deltas accumulate reconstructed text in order")
    func generationDeltasAccumulateText() {
        var state = ChatTurnState(turnIndex: 0)
        let instant0 = clock.now
        let instant1 = clock.now

        ChatEventReducer.reduce(.generation("Moon"), into: &state, now: instant0)
        ChatEventReducer.reduce(.generation("light"), into: &state, now: instant1)

        #expect(state.response.reconstructedText == "Moonlight")
    }

    @Test("Thinking deltas accumulate separately from generation text")
    func thinkingDeltasAccumulateSeparately() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.thinking("Let me consider "), into: &state, now: now)
        ChatEventReducer.reduce(.thinking("the options."), into: &state, now: now)
        ChatEventReducer.reduce(.generation("Here is the answer."), into: &state, now: now)

        #expect(state.response.thinking == "Let me consider the options.")
        #expect(state.response.reconstructedText == "Here is the answer.")
    }

    @Test("Tool call deltas capture arguments before execution")
    func toolCallDeltaCapturesArguments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "search", arguments: "{\"query\":\"moon\"}")),
            into: &state,
            now: now
        )

        let trace = state.tools["call-1"]
        #expect(trace?.name == "search")
        #expect(trace?.arguments == "{\"query\":\"moon\"}")
        #expect(trace?.state == .attempting)
        #expect(trace?.startedAt == nil)
        #expect(state.orderedTools.map(\.id) == ["call-1"])
        #expect(state.response.reconstructedText.isEmpty)
    }

    @Test("Attempting status creates a tool trace and records a start time")
    func attemptingCreatesTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.name == "search")
        #expect(trace?.state == .attempting)
        #expect(trace?.startedAt == startedAt)
        #expect(trace?.finishedAt == nil)
        #expect(state.orderedTools.map(\.id) == ["call-1"])
    }

    @Test("Success status transitions an attempting trace and records output")
    func successTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("3 results"))),
            into: &state,
            now: finishedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.state == .succeeded)
        #expect(trace?.output == "3 results")
        #expect(trace?.error == nil)
        #expect(trace?.startedAt == startedAt)
        #expect(trace?.finishedAt == finishedAt)
    }

    @Test("Tool trace DTO preserves arguments and output")
    func toolTraceDTOPreservesArgumentsAndOutput() throws {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "calculator", arguments: "{\"expression\":\"2 + 2\"}")),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("4"))),
            into: &state,
            now: now
        )

        let dto = try #require(state.toolTraceDTOs.first)
        #expect(dto.arguments == "{\"expression\":\"2 + 2\"}")
        #expect(dto.output == "4")
    }

    @Test("Failed status transitions a trace, captures error, and uses the reference display name")
    func failedTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .failed(reference: .known(id: "search"), error: "timeout")),
            into: &state,
            now: finishedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.state == .failed)
        #expect(trace?.error == "timeout")
        #expect(trace?.finishedAt == finishedAt)
    }

    @Test("Failure(message) status (tool-not-found style) also transitions the trace")
    func failureMessageTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .failure("not found")),
            into: &state,
            now: now
        )

        #expect(state.tools["call-1"]?.state == .failed)
        #expect(state.tools["call-1"]?.error == "not found")
    }

    @Test("toolCallError event creates/marks a trace as failed, even without a prior attempting status")
    func toolCallErrorEventMarksFailed() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCallError(toolCallId: "call-2", name: "search", error: "invalid arguments"),
            into: &state,
            now: now
        )

        let trace = state.tools["call-2"]
        #expect(trace?.name == "search")
        #expect(trace?.state == .failed)
        #expect(trace?.error == "invalid arguments")
        #expect(state.orderedTools.map(\.id) == ["call-2"])
    }

    @Test("Multiple tools preserve first-seen order in orderedTools")
    func multipleToolsPreserveOrder() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-b", status: .attempting(name: "second", reference: .known(id: "second"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-a", status: .attempting(name: "first", reference: .known(id: "first"))),
            into: &state,
            now: now
        )

        #expect(state.orderedTools.map(\.id) == ["call-b", "call-a"])
    }

    @Test("generationContext meta event records touched workspace files")
    func generationContextRecordsFiles() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .generationContext(ChatMetadata(memories: [], files: ["notes/today.md", "todo.txt"])),
            into: &state,
            now: now
        )

        #expect(state.workspaceFiles == ["notes/today.md", "todo.txt"])
    }

    @Test("generationCancelled marks the turn cancelled without completing it")
    func generationCancelledMarksCancelled() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generationCancelled(), into: &state, now: now)

        #expect(state.isCancelled)
        #expect(!state.isComplete)
    }

    @Test("error(message:) records errorMessage on the turn state")
    func errorMessageIsRecorded() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.error("network blip"), into: &state, now: now)

        #expect(state.errorMessage == "network blip")
    }

    @Test("streamCompleted marks the turn complete (terminal)")
    func streamCompletedMarksComplete() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.streamCompleted(), into: &state, now: now)

        #expect(state.isComplete)
    }

    @Test("completion(generationCompleted) records final response metadata")
    func completionRecordsResponseMetadata() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now
        let message = Message(content: "Final answer", role: .assistant)
        let metadata = APIResponseMetadata(
            model: "gpt-test",
            promptTokens: 12,
            completionTokens: 34,
            totalTokens: 46,
            finishReason: "stop"
        )

        ChatEventReducer.reduce(.generationCompleted(message: message, metadata: metadata), into: &state, now: now)

        #expect(state.response.model == "gpt-test")
        #expect(state.response.finishReason == "stop")
        #expect(state.response.inputTokens == 12)
        #expect(state.response.outputTokens == 34)
    }

    @Test("A completed turn never mutates: events after streamCompleted are ignored")
    func completedTurnNeverMutates() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("first"), into: &state, now: now)
        ChatEventReducer.reduce(.streamCompleted(), into: &state, now: now)
        #expect(state.isComplete)

        // Late/stray events after completion must not mutate the finalized state.
        ChatEventReducer.reduce(.generation("late text"), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-late", status: .attempting(name: "late", reference: .known(id: "late"))),
            into: &state,
            now: now
        )
        let metadata = APIResponseMetadata(model: "should-not-apply")
        ChatEventReducer.reduce(.generationCompleted(message: Message(content: "x", role: .assistant), metadata: metadata), into: &state, now: now)

        #expect(state.response.reconstructedText == "first")
        #expect(state.orderedTools.isEmpty)
        #expect(state.response.model == nil)
    }

    @Test("ToolTrace.elapsed derives duration from startedAt/finishedAt instants")
    func toolTraceElapsedDerivesDuration() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        Thread.sleep(forTimeInterval: 0.001)
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("ok"))),
            into: &state,
            now: finishedAt
        )

        let elapsed = state.tools["call-1"]?.elapsed
        #expect(elapsed != nil)
        #expect((elapsed ?? .zero) > .zero)
    }

    @Test("responseDTO reflects accumulated text, thinking, and metadata")
    func responseDTOReflectsAccumulatedState() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.thinking("pondering"), into: &state, now: now)
        ChatEventReducer.reduce(.generation("answer"), into: &state, now: now)
        let metadata = APIResponseMetadata(model: "gpt-test", promptTokens: 1, completionTokens: 2, finishReason: "stop")
        ChatEventReducer.reduce(.generationCompleted(message: Message(content: "answer", role: .assistant), metadata: metadata), into: &state, now: now)

        let dto = state.responseDTO
        #expect(dto.reconstructedText == "answer")
        #expect(dto.thinking == "pondering")
        #expect(dto.model == "gpt-test")
        #expect(dto.finishReason == "stop")
        #expect(dto.inputTokens == 1)
        #expect(dto.outputTokens == 2)
    }
}
