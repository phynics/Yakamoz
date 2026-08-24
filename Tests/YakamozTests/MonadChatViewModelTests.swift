import ErrorKit
import Foundation
import MonadClient
import MonadShared
import PKContracts
import PositronicKit
import Testing
@testable import YakamozCore

/// YAK-MON-7: tests for `MonadChatViewModel` driving a Monad-mode transcript from
/// scripted `TurnEvent` streams — no live network. The `ChatEventReducer` and
/// `ChatViewModel` are exercised through the `ChatRunning` seam, proving
/// Monad-mode streaming works end-to-end through the existing reducer.
@Suite("MonadChatViewModel")
@MainActor
struct MonadChatViewModelTests {
    private final class ScriptedRunner: ChatRunning, @unchecked Sendable {
        private(set) var capturedMessages: [String] = []
        private(set) var lastSystemInstructions: String?
        var continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation?
        var throwOnError: Error?
        private let runCounter = AsyncCounter()
        private let continuationCounter = AsyncCounter()

        func waitUntilRunCount(_ count: Int) async {
            await runCounter.wait(until: count)
        }

        func waitUntilContinuationCount(_ count: Int) async {
            await continuationCounter.wait(until: count)
        }

        func run(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
            capturedMessages.append(request.message)
            lastSystemInstructions = request.systemInstructions
            runCounter.increment()
            if let throwOnError {
                throw throwOnError
            }
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
                self.continuationCounter.increment()
                continuation.onTermination = { @Sendable _ in
                    continuation.finish()
                }
            }
        }
    }

    fileprivate actor FakeTransport: MonadClientTransport {
        var statusResult: Result<StatusResponse, Error> = .failure(MonadClientError.serverNotReachable)
        var timelines: [TimelineResponse] = []
        var executeResult: Result<[TurnEvent], Error> = .success([])
        var executeError: MonadClientError?

        func getStatus() async throws -> StatusResponse {
            try statusResult.get()
        }

        func listTimelines() async throws -> [TimelineResponse] {
            timelines
        }

        func createTimeline(title: String?) async throws -> TimelineResponse {
            let timeline = TimelineResponse(id: UUID(), title: title)
            timelines.append(timeline)
            return timeline
        }

        func getTimeline(id: UUID) async throws -> TimelineResponse {
            if let match = timelines.first(where: { $0.id == id }) {
                return match
            }
            throw MonadClientError.notFound
        }

        func execute(
            timelineId: UUID,
            message: String,
            toolOutputs _: [ToolOutputSubmission]?,
            clientTools _: [ToolReference]?
        ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
            if let executeError {
                throw executeError
            }
            let events = try executeResult.get()
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func listAgentInstances() async throws -> [AgentInstance] {
            []
        }

        func listAgentTemplates() async throws -> [AgentTemplate] {
            []
        }

        func getAgentTimelines(agentId _: UUID) async throws -> [TimelineResponse] {
            []
        }

        func listWorkspaces() async throws -> [WorkspaceReference] {
            []
        }

        func attachWorkspace(_: UUID, to _: UUID) async throws {}

        func detachWorkspace(_: UUID, from _: UUID) async throws {}

        func listTimelineWorkspaces(timelineId _: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
            (primary: nil, attached: [])
        }
    }

    @Test("Text delta streaming renders incrementally into the transcript")
    func textDeltaStreaming() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.generation("Hello"))
        runner.continuation?.yield(.generation(", world"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        #expect(vm.chatViewModel.transcript.count == 2)

        guard case let .user(_, userText, _) = vm.chatViewModel.transcript[0] else {
            Issue.record("Expected first transcript item to be .user")
            return
        }
        #expect(userText == "Hello")

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript[1] else {
            Issue.record("Expected second transcript item to be .assistant")
            return
        }
        #expect(turn.response.reconstructedText == "Hello, world")
        #expect(turn.isComplete)
        #expect(!turn.isCancelled)
        #expect(turn.errorMessage == nil)
    }

    @Test("Thinking/reasoning deltas render in the turn state")
    func reasoningDeltaStreaming() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Think about this")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.reasoning("Let me think..."))
        runner.continuation?.yield(.reasoning(" step by step."))
        runner.continuation?.yield(.generation("Here is the answer."))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.response.thinking == "Let me think... step by step.")
        #expect(turn.response.reconstructedText == "Here is the answer.")
        #expect(turn.isComplete)
    }

    @Test("Tool call and tool result render in the turn state")
    func toolCallAndResultRendering() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Read the file")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        let toolCallId = "call-1"
        let toolName = "read_file"
        let reference = ToolReference.known("read_file")

        runner.continuation?.yield(.toolCall(ToolCallDelta(
            index: 0, id: toolCallId, name: toolName, arguments: "{\"path\":\"/tmp/test.txt\"}"
        )))
        runner.continuation?.yield(.toolProgress(
            toolCallID: toolCallId,
            status: .attempting(name: toolName, reference: reference)
        ))
        runner.continuation?.yield(.toolCompleted(
            toolCallID: toolCallId,
            status: .success(ToolResult.success("File contents here"))
        ))
        runner.continuation?.yield(.generation("The file contains: File contents here"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.orderedTools.count == 1)
        let trace = turn.orderedTools.first
        #expect(trace?.name == toolName)
        #expect(trace?.state == .succeeded)
        #expect(trace?.output == "File contents here")
        #expect(trace?.arguments == "{\"path\":\"/tmp/test.txt\"}")
        #expect(turn.response.reconstructedText == "The file contains: File contents here")
        #expect(turn.isComplete)
    }

    @Test("Server error surfaces as userFriendlyMessage in errorMessage")
    func serverErrorSurfacesAsUserFriendlyMessage() async throws {
        let runner = ScriptedRunner()
        runner.throwOnError = MonadBackendHealthError.authenticationFailed
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await vm.awaitSendCompletion()

        let errorMessage = vm.chatViewModel.errorMessage
        #expect(errorMessage != nil)
        #expect(errorMessage == ErrorKit.userFriendlyMessage(for: MonadBackendHealthError.authenticationFailed))

        let errorItems = vm.chatViewModel.transcript.filter { item in
            if case .error = item { return true }
            return false
        }
        #expect(errorItems.count == 1)

        if case let .error(_, message, retryPrompt) = errorItems.first {
            #expect(message == ErrorKit.userFriendlyMessage(for: MonadBackendHealthError.authenticationFailed))
            #expect(retryPrompt == "Hello")
        }
    }

    @Test("Unreachable server error surfaces with the underlying message")
    func unreachableErrorSurfaces() async throws {
        let runner = ScriptedRunner()
        runner.throwOnError = MonadBackendHealthError.unreachable(underlying: "connection refused")
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await vm.awaitSendCompletion()

        let errorMessage = vm.chatViewModel.errorMessage
        #expect(errorMessage != nil)
        #expect(errorMessage == ErrorKit.userFriendlyMessage(
            for: MonadBackendHealthError.unreachable(underlying: "connection refused")
        ))
    }

    @Test("Transport error through MonadYakamozBackend maps to MonadBackendHealthError and surfaces")
    func transportErrorThroughBackendSurfaces() async throws {
        let transport = FakeTransport()
        await transport.setExecuteError(MonadClientError.unauthorized)
        let backend = MonadYakamozBackend(transport: transport)
        let vm = MonadChatViewModel(timelineId: UUID(), runner: backend)

        vm.send("Hello")
        await vm.awaitSendCompletion()

        let errorMessage = vm.chatViewModel.errorMessage
        #expect(errorMessage != nil)
        #expect(errorMessage == ErrorKit.userFriendlyMessage(for: MonadBackendHealthError.authenticationFailed))
    }

    @Test("Cancellation marks the turn as cancelled")
    func cancellationInterruption() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.generation("Partial response"))
        runner.continuation?.yield(.generationCancelled())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.isCancelled)
        #expect(turn.response.reconstructedText == "Partial response")
    }

    @Test("Cancel() interrupts the in-flight stream")
    func cancelInterruptsStream() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.generation("Partial"))
        vm.cancel()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.isCancelled)
    }

    @Test("Empty model turn surfaces the empty-response notice")
    func emptyModelTurn() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.completedEmpty(finishReason: "stop"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.isComplete)
        #expect(turn.response.reconstructedText.contains("empty response"))
    }

    @Test("Partial turn preserves streamed content before stream ends")
    func partialTurnPreservesContent() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.generation("First part. "))
        runner.continuation?.yield(.generation("Second part."))
        runner.continuation?.finish(throwing: MonadBackendHealthError.incompatibleResponse(underlying: "bad frame"))
        await vm.awaitSendCompletion()

        let assistantItems = vm.chatViewModel.transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }
        guard let turn = assistantItems.last else {
            Issue.record("Expected an assistant item with streamed content")
            return
        }
        #expect(turn.response.reconstructedText == "First part. Second part.")
        #expect(turn.errorMessage != nil)

        let hasErrorItem = vm.chatViewModel.transcript.contains { item in
            if case .error = item { return true }
            return false
        }
        #expect(hasErrorItem)
    }

    @Test("Retry failed turn resubmits the original prompt")
    func retryFailedTurn() async throws {
        let runner = ScriptedRunner()
        runner.throwOnError = MonadBackendHealthError.authenticationFailed
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Original prompt")
        await vm.awaitSendCompletion()

        #expect(runner.capturedMessages == ["Original prompt"])
        #expect(vm.chatViewModel.errorMessage != nil)

        let errorId: UUID? = vm.chatViewModel.transcript.compactMap { item in
            if case let .error(id, _, _) = item { return id } else { return nil }
        }.first
        guard let errorId else {
            Issue.record("Expected an error transcript item")
            return
        }

        runner.throwOnError = nil
        vm.retryFailedTurn(errorId: errorId)
        await runner.waitUntilRunCount(2)
        await runner.waitUntilContinuationCount(1)

        runner.continuation?.yield(.generation("Recovered!"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        #expect(runner.capturedMessages == ["Original prompt", "Original prompt"])
        #expect(vm.chatViewModel.errorMessage == nil)

        let hasErrorItem = vm.chatViewModel.transcript.contains { item in
            if case .error = item { return true }
            return false
        }
        #expect(!hasErrorItem)
    }

    @Test("isSending is true during streaming and false after completion")
    func isSendingStateTransitions() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Hello")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        #expect(vm.chatViewModel.isSending)

        runner.continuation?.yield(.generation("Response"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        #expect(!vm.chatViewModel.isSending)
    }

    @Test("System instructions are forwarded to the runner")
    func systemInstructionsForwarded() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(
            timelineId: UUID(),
            runner: runner,
            systemInstructions: "You are a Monad agent."
        )

        vm.send("Hello")
        await runner.waitUntilRunCount(1)

        #expect(runner.lastSystemInstructions == "You are a Monad agent.")

        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()
    }

    @Test("Blank text is a no-op")
    func blankTextIsNoOp() async {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("   \n  ")

        #expect(vm.chatViewModel.transcript.isEmpty)
        #expect(!vm.chatViewModel.isSending)
    }

    @Test("Tool execution error renders as a failed trace")
    func toolExecutionErrorRenders() async throws {
        let runner = ScriptedRunner()
        let vm = MonadChatViewModel(timelineId: UUID(), runner: runner)

        vm.send("Run the tool")
        await runner.waitUntilRunCount(1)
        await runner.waitUntilContinuationCount(1)

        let toolCallId = "call-err"
        let toolName = "run_command"
        let reference = ToolReference.known("run_command")

        runner.continuation?.yield(.toolCall(ToolCallDelta(
            index: 0, id: toolCallId, name: toolName, arguments: "{}"
        )))
        runner.continuation?.yield(.toolProgress(
            toolCallID: toolCallId,
            status: .attempting(name: toolName, reference: reference)
        ))
        runner.continuation?.yield(.toolCallError(
            toolCallID: toolCallId,
            name: toolName,
            error: "Permission denied"
        ))
        runner.continuation?.yield(.generation("I couldn't run that command."))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        await vm.awaitSendCompletion()

        guard case let .assistant(_, turn) = vm.chatViewModel.transcript.last else {
            Issue.record("Expected an assistant item")
            return
        }
        #expect(turn.orderedTools.count == 1)
        let trace = turn.orderedTools.first
        #expect(trace?.state == .failed)
        #expect(trace?.error == "Permission denied")
        #expect(turn.response.reconstructedText == "I couldn't run that command.")
    }
}

private extension MonadChatViewModelTests.FakeTransport {
    func setExecuteResult(_ result: Result<[TurnEvent], Error>) {
        executeResult = result
    }

    func setExecuteError(_ error: MonadClientError) {
        executeError = error
    }
}
