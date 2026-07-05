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
    private(set) var lastStructuredOutput: StructuredOutputRequest?
    private(set) var lastSendId: UUID?
    private(set) var lastSystemInstructions: String?
    var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    var onRun: (@Sendable (String) -> Void)?
    private let runCounter = AsyncCounter()
    private let continuationCounter = AsyncCounter()

    func waitUntilRunCount(_ count: Int) async {
        await runCounter.wait(until: count)
    }

    func waitUntilContinuationCount(_ count: Int) async {
        await continuationCounter.wait(until: count)
    }

    func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        capturedMessages.append(request.message)
        lastStructuredOutput = request.structuredOutput
        lastSendId = request.sendId
        lastSystemInstructions = request.systemInstructions
        onRun?(request.message)
        runCounter.increment()
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.continuationCounter.increment()
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
    func sendInsertsUserItemAndSetsIsSending() async {
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
        await runner.waitUntilRunCount(1)
        #expect(viewModel.transcript.count == 2)
        #expect(runner.capturedMessages == ["hello there"])

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Timeline state callback publishes running immediately, then completed")
    func timelineStatePublishesRunningThenCompleted() async throws {
        let runner = ScriptedRunner()
        let states = LockedStateLog()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            onTimelineStateChange: { state in
                await states.append(state)
            }
        )

        viewModel.send("hello there")
        try await waitUntilAsync { await states.snapshot().first == .running }

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()

        let recorded = await states.snapshot()
        #expect(recorded == [.running, .completed])
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
    func sendWhileSendingIsNoOp() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("first")
        await runner.waitUntilRunCount(1)
        #expect(viewModel.isSending)

        viewModel.send("second")

        // Only the first message should have reached the runner.
        #expect(runner.capturedMessages == ["first"])

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Typed reply conversations forward the structured output schema to the runner")
    func typedReplyConversationsForwardStructuredOutputSchema() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            structuredOutput: TypedReply.request(),
            typedReplyEnabled: true
        )

        viewModel.send("summarize this")

        await runner.waitUntilRunCount(1)
        #expect(runner.lastStructuredOutput == TypedReply.request())

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Live delta events update the assistant transcript item incrementally")
    func liveDeltaEventsUpdateTranscript() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("tell me a story")
        await runner.waitUntilContinuationCount(1)

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
        await viewModel.awaitSendCompletion()

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

        viewModel.send("hi")
        await runner.waitUntilContinuationCount(1)

        // Seed a TurnInspectionModel row for turn 0 the way `didComposeTurn` would,
        // so `updateResponse` has a row to enrich (Task 3 + Task 6 wiring). The row's
        // identity must match the sendId ChatViewModel generated for this send (visible
        // only once the runner has captured the request), since `persistResponse` looks
        // up the terminal round-trip by sendId, not by a conversation-wide latest row.
        let sendId = try #require(runner.lastSendId)
        let prompt = AnyPrompt.build { SystemPrompt("You are helpful") }
        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()
        let seedInspection = TurnInspection(
            identity: TurnIdentity(sendId: sendId, roundTrip: 0),
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

        runner.continuation?.yield(.generation("hello back"))
        runner.continuation?.yield(.generationCompleted(
            message: Message(content: "hello back", role: .assistant),
            metadata: APIResponseMetadata(model: "gpt-test", finishReason: "stop")
        ))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()

        await viewModel.awaitSendCompletion()

        let persisted = try await inspector.inspection(conversationId: timelineId, turnIndex: 0)
        let response = try #require(persisted?.response)
        #expect(response.reconstructedText == "hello back")
        #expect(response.model == "gpt-test")
        #expect(response.finishReason == "stop")
    }

    @Test("A stream that ends without an explicit streamCompleted still finalizes and persists")
    func normalStreamEndFinalizesTurn() async throws {
        // The real ChatEngine ends its stream by finishing the continuation; it never emits
        // a synthetic `.streamCompleted`. The view model must treat that clean end as
        // completion so the response is persisted.
        let runner = ScriptedRunner()
        let inspector = try makeInspector()
        let timelineId = UUID()
        let viewModel = ChatViewModel(timelineId: timelineId, runner: runner, inspector: inspector)

        viewModel.send("hi")
        await runner.waitUntilContinuationCount(1)

        // Seed after the run starts so the row's identity matches the sendId
        // ChatViewModel generated for this send (see completionPersistsResponseViaInspector).
        let sendId = try #require(runner.lastSendId)
        let prompt = AnyPrompt.build { SystemPrompt("You are helpful") }
        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()
        await inspector.didComposeTurn(TurnInspection(
            identity: TurnIdentity(sendId: sendId, roundTrip: 0),
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
        ))

        runner.continuation?.yield(.generation("final answer"))
        // No `.streamCompleted` — just finish the stream, like the real engine.
        runner.continuation?.finish()

        await viewModel.awaitSendCompletion()

        guard case let .assistant(_, turn) = viewModel.transcript.last else {
            Issue.record("Expected assistant item")
            return
        }
        #expect(turn.isComplete)
        #expect(turn.response.reconstructedText == "final answer")

        let persisted = try await inspector.inspection(conversationId: timelineId, turnIndex: 0)
        #expect(persisted?.response?.reconstructedText == "final answer")
    }

    @Test("TEX-2: tool-guidance line is appended to system instructions when tools are offered")
    func toolGuidanceAppendedWhenToolsOffered() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            tools: [CalculatorTool().toAnyTool()],
            systemInstructions: "You are a helpful assistant."
        )

        viewModel.send("hi")
        await runner.waitUntilRunCount(1)

        let instructions = try? #require(runner.lastSystemInstructions)
        #expect(instructions?.contains("You are a helpful assistant.") == true)
        #expect(instructions?.contains(ToolExplanationParameter.key) == true)

        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("TEX-2: system instructions are unchanged when the conversation has no tools")
    func systemInstructionsUnchangedWithoutTools() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            tools: [],
            systemInstructions: "You are a helpful assistant."
        )

        viewModel.send("hi")
        await runner.waitUntilRunCount(1)

        #expect(runner.lastSystemInstructions == "You are a helpful assistant.")

        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("TEX-2: tool-guidance line is present even with nil base system instructions, when tools are offered")
    func toolGuidancePresentWithNilBaseInstructions() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            tools: [CalculatorTool().toAnyTool()],
            systemInstructions: nil
        )

        viewModel.send("hi")
        await runner.waitUntilRunCount(1)

        #expect(runner.lastSystemInstructions?.contains(ToolExplanationParameter.key) == true)

        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("A clean empty stream surfaces an explicit empty-response notice")
    func emptyStreamSurfacesNotice() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            tools: [CalculatorTool().toAnyTool()]
        )

        viewModel.send("use a tool if needed")
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.finish()

        await viewModel.awaitSendCompletion()

        guard case let .assistant(_, turn) = viewModel.transcript.last else {
            Issue.record("Expected assistant item")
            return
        }
        #expect(turn.isComplete)
        #expect(turn.response.reconstructedText.contains("The model returned an empty response."))
        #expect(turn.response.reconstructedText.contains("tool-capable model"))
    }

    @Test("Cancelling marks the in-flight turn as cancelled and stops sending")
    func cancelMarksTurnCancelled() async {
        let runner = ScriptedRunner()
        let states = LockedStateLog()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            onTimelineStateChange: { state in
                await states.append(state)
            }
        )

        viewModel.send("long running request")
        await runner.waitUntilContinuationCount(1)

        viewModel.cancel()

        await viewModel.awaitSendCompletion()

        guard case let .assistant(_, turn) = viewModel.transcript.last else {
            Issue.record("Expected final transcript item to be .assistant")
            return
        }
        #expect(turn.isCancelled)
        #expect(await states.snapshot().suffix(1).first == .cancelled)
    }

    @Test("cancel() is idempotent — extra calls around finalization are no-ops (STAB-11)")
    func cancelIsIdempotentAcrossLifecycleHooks() async {
        // `ChatView` now invokes `cancel()` from several view-lifecycle hooks that may
        // overlap (the `buildViewModelIfNeeded` replacement site plus `.onDisappear` on
        // window close). That is only safe because `cancel()` is idempotent: a nil or
        // already-cancelled/completed `sendTask` makes `sendTask?.cancel()` a no-op.
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        // No turn in flight: cancel is a no-op and leaves the view model untouched.
        viewModel.cancel()
        #expect(!viewModel.isSending)
        #expect(viewModel.transcript.isEmpty)

        viewModel.send("streaming turn")
        await runner.waitUntilContinuationCount(1)

        // Multiple hooks may fire before/during finalization; each extra cancel is a no-op.
        viewModel.cancel()
        viewModel.cancel()
        viewModel.cancel()

        await viewModel.awaitSendCompletion()

        guard case let .assistant(_, turn) = viewModel.transcript.last else {
            Issue.record("Expected final transcript item to be .assistant")
            return
        }
        #expect(turn.isCancelled)

        // After finalization the sendTask reference is completed; further cancels (e.g. a
        // late `.onDisappear`) remain no-ops and do not mutate state or throw.
        viewModel.cancel()
        #expect(!viewModel.isSending)
    }

    @Test("A surfaced .error(message:) event sets errorMessage on the view model")
    func errorEventSurfacesMessage() async {
        let runner = ScriptedRunner()
        let states = LockedStateLog()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            onTimelineStateChange: { state in
                await states.append(state)
            }
        )

        viewModel.send("trigger an error")
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.error("the provider rejected the request"))
        // Await the turn's real completion signal (YAK-44): consume processes the error
        // event, sets errorMessage, and finishes — at which point errorMessage is set.
        await viewModel.awaitSendCompletion()

        #expect(viewModel.errorMessage == "the provider rejected the request")
        #expect(viewModel.transcript.contains(where: { item in
            if case let .error(_, message, _) = item {
                return message == "the provider rejected the request"
            }
            return false
        }))
        #expect(!viewModel.transcript.contains(where: { item in
            if case .assistant = item {
                return true
            }
            return false
        }))

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
        #expect(await states.snapshot().suffix(1).first == .failed)
    }

    @Test("Approval-style errors publish blocked timeline state by structured identity (STAB-6)")
    func approvalErrorPublishesBlockedState() async {
        let runner = ScriptedRunner()
        let states = LockedStateLog()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            onTimelineStateChange: { state in
                await states.append(state)
            }
        )

        viewModel.send("run blocked command")
        await runner.waitUntilContinuationCount(1)

        // Yield a structured PKError (permission denied) so the reducer carries the
        // blocked identity and the timeline state classifies as `.blocked`. A
        // bare-string "denied" message would now (correctly) classify as `.failed`.
        runner.continuation?.yield(.error(ToolError.permissionDenied("rm")))
        // Await the turn's real completion signal (YAK-44): consume processes the
        // structured error, publishes .blocked, and finishes — so .blocked is in the
        // log by the time we resume.
        await viewModel.awaitSendCompletion()
        #expect(await states.snapshot().suffix(1).first == .blocked)
    }

    @Test("A thrown error from the runner surfaces as errorMessage and marks the turn errored")
    func thrownErrorSurfacesMessage() async {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }
        let runner = ThrowingRunner(error: BoomError())
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("this will throw")

        await viewModel.awaitSendCompletion()
        #expect(viewModel.errorMessage == "boom")
        #expect(viewModel.transcript.count == 2)
        guard case .user = viewModel.transcript[0] else {
            Issue.record("Expected user item to remain")
            return
        }
        guard case let .error(_, message, _) = viewModel.transcript[1] else {
            Issue.record("Expected thrown failure to be shown as an error item")
            return
        }
        #expect(message == "boom")
    }

    @Test("A thrown PKError surfaces its userFriendlyMessage without the [domain:code] prefix (STAB-4)")
    func thrownPKErrorSurfacesUserFriendlyMessage() async {
        let thrown = ToolError.missingArgument("query")
        let runner = ThrowingRunner(error: thrown)
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("this will throw")

        await viewModel.awaitSendCompletion()

        let expected = thrown.userFriendlyMessage
        #expect(viewModel.errorMessage == expected)
        #expect(!(viewModel.errorMessage ?? "").contains("[\(thrown.errorDomain):\(thrown.errorCode)]"))
        guard case let .error(_, message, _) = viewModel.transcript[1] else {
            Issue.record("Expected thrown failure to be shown as an error item")
            return
        }
        #expect(message == expected)
    }

    @Test("A thrown blocked PKError publishes a blocked timeline state (STAB-6)")
    func thrownBlockedPKErrorPublishesBlockedState() async {
        let thrown = ToolError.permissionDenied("rm")
        let runner = ThrowingRunner(error: thrown)
        let states = LockedStateLog()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            onTimelineStateChange: { state in
                await states.append(state)
            }
        )

        viewModel.send("this will throw a blocked error")

        await viewModel.awaitSendCompletion()
        #expect(await states.snapshot().suffix(1).first == .blocked)
        #expect(viewModel.errorMessage == thrown.userFriendlyMessage)
    }

    @Test("A chat prompt can be presented and dismissed without becoming a message")
    func chatPromptCanBePresentedAndDismissed() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)
        let prompt = ChatPrompt(
            title: "Attach a folder?",
            options: [
                ChatPromptOption(id: "documents", title: "Documents", systemImage: "folder"),
                ChatPromptOption(id: "choose", title: "Choose Folder", systemImage: "folder.badge.plus"),
            ]
        )

        let promptId = viewModel.presentPrompt(prompt)

        #expect(viewModel.transcript.count == 1)
        guard case let .prompt(id, shownPrompt) = viewModel.transcript[0] else {
            Issue.record("Expected prompt transcript item")
            return
        }
        #expect(id == promptId)
        #expect(shownPrompt.title == "Attach a folder?")
        #expect(shownPrompt.options.map(\.id) == ["documents", "choose"])

        viewModel.dismissTranscriptItem(id: promptId)

        #expect(viewModel.transcript.isEmpty)
    }

    @Test("Prompt rows do not affect the next assistant turn index")
    func promptRowsDoNotAffectTurnIndexing() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .assistant(id: UUID(), turn: ChatTurnState(turnIndex: 3)),
                .prompt(
                    id: UUID(),
                    prompt: ChatPrompt(
                        title: "Attach a folder?",
                        options: [ChatPromptOption(id: "skip", title: "Skip", systemImage: "xmark")]
                    )
                ),
            ]
        )

        viewModel.send("next")
        await runner.waitUntilRunCount(1)

        #expect(viewModel.selectedTurnIndex == 4)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Turn selection tracks the most recently started turn")
    func turnSelectionTracksLatestTurn() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("first turn")
        await runner.waitUntilRunCount(1)
        #expect(viewModel.selectedTurnIndex == 0)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()

        viewModel.send("second turn")
        await runner.waitUntilRunCount(2)
        #expect(viewModel.selectedTurnIndex == 1)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Bubble selection can target a distinct persisted inspection row")
    func bubbleSelectionMapsToInspectionRow() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .assistant(
                    id: UUID(),
                    turn: {
                        var turn = ChatTurnState(turnIndex: 3)
                        turn.inspectionTurnIndex = 7
                        return turn
                    }()
                ),
            ]
        )

        viewModel.selectTurn(3)

        #expect(viewModel.selectedTurnIndex == 3)
        #expect(viewModel.selectedInspectionTurnIndex == 7)

        viewModel.selectInspectionTurn(7)
        #expect(viewModel.selectedTurnIndex == 3)
        #expect(viewModel.selectedInspectionTurnIndex == 7)
    }

    @Test("Nil direct inspection selection clears transcript selection")
    func nilInspectionSelectionClearsTranscriptSelection() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .assistant(
                    id: UUID(),
                    turn: {
                        var turn = ChatTurnState(turnIndex: 3)
                        turn.inspectionTurnIndex = 7
                        return turn
                    }()
                ),
            ]
        )

        viewModel.selectTurn(3)
        viewModel.selectInspectionTurn(nil)

        #expect(viewModel.selectedTurnIndex == nil)
        #expect(viewModel.selectedInspectionTurnIndex == nil)
    }

    @Test("Direct inspection selection ignores nonexistent transcript turns")
    func missingInspectionSelectionPreservesCurrentSelection() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .assistant(
                    id: UUID(),
                    turn: {
                        var turn = ChatTurnState(turnIndex: 3)
                        turn.inspectionTurnIndex = 7
                        return turn
                    }()
                ),
            ]
        )

        viewModel.selectTurn(3)
        viewModel.selectInspectionTurn(8)

        #expect(viewModel.selectedTurnIndex == 3)
        #expect(viewModel.selectedInspectionTurnIndex == 7)
    }

    @Test("Direct inspection selection exposes selectable turn availability")
    func directInspectionSelectionAvailability() {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .assistant(
                    id: UUID(),
                    turn: {
                        var turn = ChatTurnState(turnIndex: 3)
                        turn.inspectionTurnIndex = 7
                        return turn
                    }()
                ),
            ]
        )

        #expect(viewModel.canSelectInspectionTurn(7))
        #expect(!viewModel.canSelectInspectionTurn(8))
    }

    @Test("A failed turn's error row carries the captured prompt and retry resubmits it (STAB-5)")
    func failedTurnErrorCarriesPromptAndRetryResubmits() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("retry me please")
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.error("provider returned 500"))
        await viewModel.awaitSendCompletion()

        guard case let .error(errorId, message, retryPrompt) = viewModel.transcript.last else {
            Issue.record("Expected final transcript item to be .error")
            return
        }
        #expect(message == "provider returned 500")
        #expect(retryPrompt == "retry me please")

        viewModel.retryFailedTurn(errorId: errorId)
        await runner.waitUntilRunCount(2)

        #expect(runner.capturedMessages == ["retry me please", "retry me please"])
        #expect(!viewModel.transcript.contains { $0.id == errorId })

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("A thrown runner error captures the prompt for retry (STAB-5)")
    func thrownErrorCapturesPromptForRetry() async {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }
        let runner = ThrowingRunner(error: BoomError())
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("will throw")

        await viewModel.awaitSendCompletion()

        guard case let .error(_, message, retryPrompt) = viewModel.transcript[1] else {
            Issue.record("Expected thrown failure to be shown as an error item")
            return
        }
        #expect(message == "boom")
        #expect(retryPrompt == "will throw")
    }

    @Test("retryFailedTurn is a no-op while a turn is in flight (STAB-5)")
    func retryIsNoOpWhileSending() async {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("in flight")
        await runner.waitUntilContinuationCount(1)

        let errorId = UUID()
        viewModel.retryFailedTurn(errorId: errorId)

        #expect(runner.capturedMessages == ["in flight"])
        #expect(viewModel.isSending)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()
    }

    @Test("Streamed deltas update the correct assistant item in a pre-populated transcript (STAB-9)")
    func streamedDeltasUpdateCorrectAssistantItemInLongTranscript() async throws {
        let runner = ScriptedRunner()
        // Pre-populate with several items so the new assistant item lands at a non-trivial
        // index (5) rather than index 1 — exercising that the recorded index tracks the
        // right slot, not just "the last item".
        let earlierAssistantId = UUID()
        var earlierTurn = ChatTurnState(turnIndex: 0)
        earlierTurn.response.reconstructedText = "earlier complete turn"
        earlierTurn.isComplete = true
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .user(id: UUID(), text: "old question", timestamp: Date()),
                .assistant(id: earlierAssistantId, turn: earlierTurn),
                .user(id: UUID(), text: "another old question", timestamp: Date()),
                .prompt(
                    id: UUID(),
                    prompt: ChatPrompt(
                        title: "Skip?",
                        options: [ChatPromptOption(id: "skip", title: "Skip", systemImage: "xmark")]
                    )
                ),
            ]
        )

        viewModel.send("stream me")
        // consume appends the assistant placeholder (and records its index) before
        // calling runner.run, so the continuation-count signal guarantees the
        // placeholder is in place — event-driven, no deadline poll (YAK-44).
        await runner.waitUntilContinuationCount(1)
        #expect(viewModel.transcript.count == 6)

        // The new assistant item is at index 5 (user send at 4, assistant at 5); the
        // recorded index should point there, not at the earlier assistant at index 1.
        #expect(viewModel.activeAssistantItemIndex == 5)

        runner.continuation?.yield(.generation("Hello "))
        try await waitUntil {
            guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
            return turn.response.reconstructedText == "Hello "
        }

        runner.continuation?.yield(.generation("world"))
        try await waitUntil {
            guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
            return turn.response.reconstructedText == "Hello world"
        }

        // The earlier assistant item is untouched.
        guard case let .assistant(id, earlierResult) = viewModel.transcript[1] else {
            Issue.record("Expected earlier assistant item at index 1 to be untouched")
            return
        }
        #expect(id == earlierAssistantId)
        #expect(earlierResult.response.reconstructedText == "earlier complete turn")
        #expect(earlierResult.isComplete)

        // The streaming item received every delta at its recorded index.
        guard case let .assistant(_, streamTurn) = viewModel.transcript[5] else {
            Issue.record("Expected streaming assistant item at index 5")
            return
        }
        #expect(streamTurn.response.reconstructedText == "Hello world")
        #expect(!streamTurn.isComplete)
        // The recorded index is still pointing at the streaming item mid-turn.
        #expect(viewModel.activeAssistantItemIndex == 5)

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await viewModel.awaitSendCompletion()

        // On turn completion the recorded index is cleared so it is never trusted
        // across turns.
        #expect(viewModel.activeAssistantItemIndex == nil)
    }

    @Test("updateAssistantItem uses the recorded index O(1) and falls back to a scan when invalid (STAB-9)")
    func updateAssistantItemFastPathAndFallback() {
        let runner = ScriptedRunner()
        let assistantId = UUID()
        var initialTurn = ChatTurnState(turnIndex: 5)
        initialTurn.response.reconstructedText = "initial"
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            initialTranscript: [
                .user(id: UUID(), text: "q", timestamp: Date()),
                .assistant(id: UUID(), turn: ChatTurnState(turnIndex: 3)),
                .assistant(id: assistantId, turn: initialTurn), // index 2
            ]
        )

        // No turn in flight → recorded index is nil → the first update must fall back to
        // a full scan (the O(1) path is skipped because there is no recorded index).
        #expect(viewModel.activeAssistantItemIndex == nil)

        var updated = initialTurn
        updated.response.reconstructedText = "updated"
        viewModel.updateAssistantItem(id: assistantId, turn: updated)

        // The fallback scan found the item at index 2 and recorded it for O(1) reuse.
        #expect(viewModel.activeAssistantItemIndex == 2)
        guard case let .assistant(_, resultTurn) = viewModel.transcript[2] else {
            Issue.record("Expected assistant item at index 2 to be updated")
            return
        }
        #expect(resultTurn.response.reconstructedText == "updated")

        // A second update uses the recorded O(1) index (no scan); the index is unchanged.
        var updatedAgain = initialTurn
        updatedAgain.response.reconstructedText = "updated again"
        viewModel.updateAssistantItem(id: assistantId, turn: updatedAgain)
        #expect(viewModel.activeAssistantItemIndex == 2)
        guard case let .assistant(_, resultTurn2) = viewModel.transcript[2] else {
            Issue.record("Expected assistant item at index 2 to be updated again")
            return
        }
        #expect(resultTurn2.response.reconstructedText == "updated again")

        // Sibling items are untouched.
        guard case .user = viewModel.transcript[0] else {
            Issue.record("Expected user item at index 0 to be untouched")
            return
        }
        guard case let .assistant(_, earlierTurn) = viewModel.transcript[1] else {
            Issue.record("Expected earlier assistant item at index 1 to be untouched")
            return
        }
        #expect(earlierTurn.turnIndex == 3)
        #expect(earlierTurn.response.reconstructedText.isEmpty)

        // An unknown id no-ops and leaves the recorded index as-is (scan finds nothing,
        // returns without re-recording).
        viewModel.updateAssistantItem(id: UUID(), turn: initialTurn)
        #expect(viewModel.activeAssistantItemIndex == 2)
        guard case let .assistant(_, unchangedTurn) = viewModel.transcript[2] else {
            Issue.record("Expected assistant item at index 2 to be unchanged")
            return
        }
        #expect(unchangedTurn.response.reconstructedText == "updated again")
    }

    @Test("An error mid-stream with visible content finalizes the assistant item and appends an error row (STAB-9)")
    func errorMidStreamWithVisibleContentFinalizesAndAppendsError() async throws {
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(timelineId: UUID(), runner: runner)

        viewModel.send("do something")
        await runner.waitUntilContinuationCount(1)

        // Stream visible content first so the assistant item has
        // `hasVisibleTranscriptContent`, which makes `finalizeFailedTurn` keep it
        // (marking `isComplete`) rather than removing it.
        runner.continuation?.yield(.generation("partial answer"))
        try await waitUntil {
            guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
            return turn.response.reconstructedText == "partial answer"
        }

        // An error event mid-stream: `finalizeFailedTurn` rewrites the assistant item in
        // place (via `updateAssistantItem`) and `appendErrorItem` mutates the transcript
        // by appending an `.error` row — the recorded index must remain valid across
        // that mutation so the right item is finalized.
        runner.continuation?.yield(.error("the provider failed"))
        await viewModel.awaitSendCompletion()

        // transcript: [user(0), assistant(1), error(2)]
        #expect(viewModel.transcript.count == 3)
        guard case .user = viewModel.transcript[0] else {
            Issue.record("Expected user item at index 0")
            return
        }
        guard case let .assistant(_, finalizedTurn) = viewModel.transcript[1] else {
            Issue.record("Expected finalized assistant item at index 1")
            return
        }
        #expect(finalizedTurn.isComplete)
        #expect(finalizedTurn.response.reconstructedText == "partial answer")
        #expect(finalizedTurn.errorMessage == "the provider failed")

        guard case let .error(_, message, retryPrompt) = viewModel.transcript[2] else {
            Issue.record("Expected error item at index 2")
            return
        }
        #expect(message == "the provider failed")
        #expect(retryPrompt == "do something")

        // The recorded index is cleared after the turn ends.
        #expect(viewModel.activeAssistantItemIndex == nil)
    }
}

private actor LockedStateLog {
    private(set) var values: [ConversationTimelineState] = []

    func append(_ state: ConversationTimelineState) {
        values.append(state)
    }

    func snapshot() -> [ConversationTimelineState] {
        values
    }
}

/// A `ChatRunning` fake whose `run` throws immediately, for exercising the
/// `consume` catch path without a scripted stream.
private struct ThrowingRunner: ChatRunning {
    let error: any Error

    func run(_: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        throw error
    }
}

/// Bounded poll for a `@MainActor` condition. This is a **last-resort backstop**
/// (YAK-44): it is used ONLY to observe transient mid-stream state for which no
/// turn-completion signal exists — specifically, assistant text deltas yielded by
/// the scripted stream BEFORE the test finishes it (e.g. `reconstructedText ==
/// "Hello "` after a `.generation` yield). Awaiting `viewModel.awaitSendCompletion()`
/// would be wrong here: the turn is intentionally still in flight (the stream is not
/// finished), so awaiting completion would deadlock. Turn-completion waits MUST use
/// `awaitSendCompletion()`; run/continuation arrival MUST use the runner's
/// `waitUntilRunCount`/`waitUntilContinuationCount`. Each poll step is a minimal
/// `Task.yield`-scale sleep; the overall timeout only exists so a real bug fails fast
/// instead of hanging.
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

/// Bounded poll for an async `@MainActor` condition. Same last-resort rationale as
/// `waitUntil` (YAK-44): used only to observe a transient mid-flight timeline state
/// (e.g. `.running` published before the stream is finished) where awaiting
/// `viewModel.awaitSendCompletion()` would deadlock because the test has not yet
/// ended the stream. Turn-completion and terminal-state (`blocked`/`cancelled`/
/// `failed`) waits use `awaitSendCompletion()` instead.
@MainActor
private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
