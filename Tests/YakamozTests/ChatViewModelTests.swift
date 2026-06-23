import Foundation
import Logging
import PKPrompt
import PKShared
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// A scripted `ChatRunning` fake: the test drives a hand-built `AsyncThrowingStream`
/// via its continuation, so `ChatViewModel` tests are deterministic and network-free.
/// No real `ChatEngine`/`PositronicKit` instance is constructed.
private final class ScriptedRunner: ChatRunning, @unchecked Sendable {
    private(set) var capturedMessages: [String] = []
    var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    var onRun: (@Sendable (String) -> Void)?

    func run(
        timelineId _: UUID,
        message: String,
        tools _: [AnyTool],
        toolOutputs _: [ToolOutputSubmission]?,
        systemInstructions _: String?,
        agentInstanceId _: UUID?,
        maxTurns _: Int,
        generationParameters _: GenerationParameters?,
        promptAssemblyLogger _: Logger?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        capturedMessages.append(message)
        onRun?(message)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            // Mirrors the real `ChatEngine` behavior (see `ChatEngine.swift`:
            // `continuation.onTermination = { task.cancel() }`): cancelling the
            // consuming Task finishes the stream's continuation, which is what lets
            // `ChatViewModel.consume`'s `for try await` loop observe cancellation
            // promptly instead of blocking forever on an event that never arrives.
            continuation.onTermination = { @Sendable _ in
                continuation.finish()
            }
        }
    }
}

@Suite("ChatViewModel")
@MainActor
struct ChatViewModelTests {
    private func makeInspector() throws -> SwiftDataTurnInspector {
        let schema = Schema([
            ConversationModel.self,
            MessageModel.self,
            TurnInspectionModel.self,
            PersonaModel.self,
            WorkspaceModel.self,
        ])
        let container = try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
        return SwiftDataTurnInspector(modelContainer: container)
    }

    @Test("Sending a message immediately inserts a user transcript item and sets isSending")
    func sendInsertsUserItemAndSetsIsSending() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("hello there")

        // The user item is inserted synchronously by `send` itself.
        #expect(viewModel.transcript.count == 1)
        guard case let .user(_, text, _) = viewModel.transcript[0] else {
            Issue.record("Expected first transcript item to be .user")
            return
        }
        #expect(text == "hello there")
        #expect(viewModel.isSending)

        // The assistant placeholder and the runner call both happen inside the
        // spawned `consume` Task; wait for them rather than asserting synchronously.
        try await waitUntil { viewModel.transcript.count == 2 }
        #expect(runner.capturedMessages == ["hello there"])

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }
    }

    @Test("Blank text is a no-op")
    func blankTextIsNoOp() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("   \n  ")

        #expect(viewModel.transcript.isEmpty)
        #expect(!viewModel.isSending)
    }

    @Test("Sending while already sending is a no-op")
    func sendWhileSendingIsNoOp() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("first")
        try await Task.sleep(for: .milliseconds(10))
        #expect(viewModel.isSending)

        viewModel.send("second")
        try await Task.sleep(for: .milliseconds(10))

        // Only the first message should have reached the runner.
        #expect(runner.capturedMessages == ["first"])

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }
    }

    @Test("Live delta events update the assistant transcript item incrementally")
    func liveDeltaEventsUpdateTranscript() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("tell me a story")
        try await Task.sleep(for: .milliseconds(10))

        runner.continuation?.yield(.generation("Once "))
        try await waitUntil {
            guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
            return turn.response.reconstructedText == "Once "
        }

        runner.continuation?.yield(.generation("upon a time"))
        try await waitUntil {
            guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
            return turn.response.reconstructedText == "Once upon a time"
        }

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }

        guard case let .assistant(_, finalTurn) = viewModel.transcript.last else {
            Issue.record("Expected final transcript item to be .assistant")
            return
        }
        #expect(finalTurn.isComplete)
        #expect(finalTurn.response.reconstructedText == "Once upon a time")
    }

    @Test("On completion, the response is persisted via the turn inspector")
    func completionPersistsResponseViaInspector() async throws {
        let runner = ScriptedRunner()
        let inspector = try makeInspector()
        let timelineId = UUID()
        let viewModel = ChatViewModel(timelineId: timelineId, runner: runner, inspector: inspector)

        // Seed a TurnInspectionModel row for turn 0 the way `didComposeTurn` would,
        // so `updateResponse` has a row to enrich (Task 3 + Task 6 wiring).
        let prompt = AnyPrompt.build { SystemPrompt("You are helpful") }
        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()
        let seedInspection = TurnInspection(
            timelineId: timelineId,
            agentInstanceId: nil,
            turnIndex: 0,
            model: "gpt-test",
            rendered: rendered,
            sentMessages: [],
            journal: TurnJournalSnapshot(
                overlay: PromptJournalDiff(changedSemiStableIDs: [], addedSemiStableIDs: [], removedSemiStableIDs: []),
                stablePrefixCount: 0,
                didCompact: false
            ),
            estimatedTokens: rendered.estimatedTokens
        )
        await inspector.didComposeTurn(seedInspection)

        viewModel.send("hi")
        try await Task.sleep(for: .milliseconds(10))

        runner.continuation?.yield(.generation("hello back"))
        runner.continuation?.yield(.generationCompleted(
            message: Message(content: "hello back", role: .assistant),
            metadata: APIResponseMetadata(model: "gpt-test", finishReason: "stop")
        ))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()

        try await waitUntil { !viewModel.isSending }

        let persisted = try await inspector.inspection(conversationId: timelineId, turnIndex: 0)
        let response = try #require(persisted?.response)
        #expect(response.reconstructedText == "hello back")
        #expect(response.model == "gpt-test")
        #expect(response.finishReason == "stop")
    }

    @Test("Cancelling marks the in-flight turn as cancelled and stops sending")
    func cancelMarksTurnCancelled() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("long running request")
        try await Task.sleep(for: .milliseconds(10))

        viewModel.cancel()

        try await waitUntil { !viewModel.isSending }

        guard case let .assistant(_, turn) = viewModel.transcript.last else {
            Issue.record("Expected final transcript item to be .assistant")
            return
        }
        #expect(turn.isCancelled)
    }

    @Test("A surfaced .error(message:) event sets errorMessage on the view model")
    func errorEventSurfacesMessage() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("trigger an error")
        try await Task.sleep(for: .milliseconds(10))

        runner.continuation?.yield(.error("the provider rejected the request"))
        try await waitUntil { viewModel.errorMessage != nil }

        #expect(viewModel.errorMessage == "the provider rejected the request")

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }
    }

    @Test("A thrown error from the runner surfaces as errorMessage and marks the turn errored")
    func thrownErrorSurfacesMessage() async throws {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }
        let runner = ThrowingRunner(error: BoomError())
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("this will throw")

        try await waitUntil { !viewModel.isSending }
        #expect(viewModel.errorMessage == "boom")
    }

    @Test("Turn selection tracks the most recently started turn")
    func turnSelectionTracksLatestTurn() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("first turn")
        try await Task.sleep(for: .milliseconds(10))
        #expect(viewModel.selectedTurnIndex == 0)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }

        viewModel.send("second turn")
        try await Task.sleep(for: .milliseconds(10))
        #expect(viewModel.selectedTurnIndex == 1)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }
    }
}

/// A `ChatRunning` fake whose `run` throws immediately, for exercising the
/// `consume` catch path without a scripted stream.
private struct ThrowingRunner: ChatRunning {
    let error: any Error

    func run(
        timelineId _: UUID,
        message _: String,
        tools _: [AnyTool],
        toolOutputs _: [ToolOutputSubmission]?,
        systemInstructions _: String?,
        agentInstanceId _: UUID?,
        maxTurns _: Int,
        generationParameters _: GenerationParameters?,
        promptAssemblyLogger _: Logger?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        throw error
    }
}

/// Polls a `@MainActor` condition without a fixed sleep duration baked into the
/// test itself; used only to await effects of a `Task` the view model spawned
/// internally (there is no other synchronization point to hook since `send` is
/// fire-and-forget by design). Each poll step is a minimal `Task.yield`-scale
/// sleep, bounded by an overall timeout so a real bug fails fast instead of hanging.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
