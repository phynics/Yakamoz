import Foundation
import PKContracts
import Testing
import YakamozCore
@testable import YakamozNetwork

/// Issue #10: remote Turns through the shared `ChatRunning` seam, driven entirely
/// offline by ``FakeGnosticTransport``.
@Suite("GnosticBackend")
@MainActor
struct GnosticBackendTests {
    private static let timelineKey = NetworkObjectKey(
        objectID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        providerID: "provider.one"
    )

    private func makeBackend(
        transport: FakeGnosticTransport,
        approver: MainActorToolApprover = MainActorToolApprover()
    ) -> GnosticBackend {
        GnosticBackend(transport: transport, approver: approver).scoped(to: Self.timelineKey)
    }

    private func makeViewModel(
        backend: GnosticBackend,
        tools: [AnyTool] = []
    ) -> ChatViewModel {
        ChatViewModel(timelineId: Self.timelineKey.objectID, runner: backend, tools: tools)
    }

    /// Yields to the turn pipeline until `condition` holds or the deadline passes.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func lastAssistantTurn(in viewModel: ChatViewModel) -> ChatTurnState? {
        viewModel.transcript.reversed().compactMap { item in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }.first
    }

    // MARK: - Inspector surface

    @Test("Network sessions publish no turn inspector")
    func inspectorUnavailable() {
        let backend = makeBackend(transport: FakeGnosticTransport())
        #expect(backend.inspectorAvailable == false)
    }

    @Test("A scoped Network backend preserves the provider-scoped Timeline key")
    func preservesTimelineKey() async throws {
        let transport = FakeGnosticTransport()
        let key = NetworkObjectKey(
            objectID: Self.timelineKey.objectID,
            providerID: "provider.two"
        )
        let backend = GnosticBackend(
            transport: transport,
            approver: MainActorToolApprover()
        ).scoped(to: key)

        let stream = try await backend.run(ChatRunRequest(
            timelineID: key.objectID,
            message: "hello",
            tools: []
        ))
        await waitUntil { await transport.turnRequests.count == 1 }

        #expect(await transport.turnRequests.first?.timelineKey == key)
        await transport.finishTurnStreams()
        for await _ in stream {}
    }

    @Test("Network backend rejects local-only request options before starting a Turn")
    func rejectsUnsupportedRequestOptions() async {
        let transport = FakeGnosticTransport()
        let backend = makeBackend(transport: transport)

        do {
            _ = try await backend.run(ChatRunRequest(
                timelineID: Self.timelineKey.objectID,
                message: "hello",
                tools: [],
                systemInstructions: "local only"
            ))
            Issue.record("expected unsupported request option failure")
        } catch let error as GnosticBackendError {
            #expect(error == .unsupportedRequestField("systemInstructions"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await transport.turnRequests.isEmpty)
    }

    // MARK: - Text streaming

    @Test("Text deltas stream into the transcript and a clean completion finalizes the turn")
    func streamsTextDeltas() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await waitUntil { await transport.turnRequests.count == 1 }
        let request = await transport.turnRequests.first
        #expect(request?.message == "hello")

        await transport.emitTurn(.textDelta("Hel"))
        await transport.emitTurn(.textDelta("lo"))
        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()

        let turn = lastAssistantTurn(in: viewModel)
        #expect(turn?.response.reconstructedText == "Hello")
        #expect(turn?.isComplete == true)
        #expect(turn?.errorMessage == nil)
        #expect(viewModel.isSending == false)
    }

    @Test("A snapshot-only turn streams the snapshot text once")
    func streamsSnapshotOnly() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.textSnapshot("Hello there"))
        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()

        #expect(lastAssistantTurn(in: viewModel)?.response.reconstructedText == "Hello there")
    }

    @Test("A snapshot after deltas emits only the missing suffix")
    func snapshotAfterDeltasEmitsSuffixOnly() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.textDelta("Hel"))
        await transport.emitTurn(.textSnapshot("Hello"))
        await transport.emitTurn(.textSnapshot("Hello"))
        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()

        #expect(lastAssistantTurn(in: viewModel)?.response.reconstructedText == "Hello")
    }

    // MARK: - Tool states

    @Test("Remote tool states become tool traces")
    func mapsToolStates() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("run it")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.toolState(GnosticTurnToolState(
            toolCallID: "call-1",
            title: "Shell",
            status: .inProgress
        )))
        await transport.emitTurn(.toolState(GnosticTurnToolState(
            toolCallID: "call-1",
            title: "Shell",
            status: .completed,
            content: "done"
        )))
        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()

        let tools = lastAssistantTurn(in: viewModel)?.orderedTools ?? []
        #expect(tools.count == 1)
        #expect(tools.first?.id == "call-1")
        #expect(tools.first?.name == "Shell")
        #expect(tools.first?.state == .succeeded)
        #expect(tools.first?.output == "done")
    }

    @Test("A failed remote tool state becomes a failed trace")
    func mapsFailedToolState() {
        let event = GnosticBackend.turnEvent(for: GnosticTurnToolState(
            toolCallID: "call-2",
            title: "Shell",
            status: .failed,
            content: "boom"
        ))
        guard case let .delta(.toolExecution(id, status)) = event else {
            Issue.record("expected a tool-execution delta, got \(String(describing: event))")
            return
        }
        #expect(id == "call-2")
        guard case let .failed(_, error) = status else {
            Issue.record("expected a failed status, got \(status)")
            return
        }
        #expect(error == "boom")
    }

    // MARK: - Failures

    @Test("A failed turn surfaces an error row and clears sending")
    func failedTurnSurfacesError() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.failed(message: "The Ascendant went away.", retryable: true))
        await viewModel.awaitSendCompletion()

        let errorRow = viewModel.transcript.last { item in
            if case .error = item { return true }
            return false
        }
        guard case let .error(_, message, retryPrompt) = errorRow else {
            Issue.record("expected an error transcript row")
            return
        }
        #expect(message == "The Ascendant went away.")
        #expect(retryPrompt == "hello")
        #expect(viewModel.isSending == false)
    }

    @Test("A transport that cannot start the turn throws and surfaces the error")
    func startFailureSurfacesError() async {
        let transport = FakeGnosticTransport()
        await transport.failNextTurns(1)
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await viewModel.awaitSendCompletion()

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isSending == false)
    }

    // MARK: - Permissions

    @Test("A pending permission request routes through the approval banner and approves back")
    func approvalSendsApproval() async {
        let transport = FakeGnosticTransport()
        let approver = MainActorToolApprover()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport, approver: approver))

        viewModel.send("do it")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.permission(GnosticTurnPermissionRequest(
            correlationID: "corr-1",
            toolCallID: "call-1",
            title: "Write a file",
            status: .pending
        )))

        await waitUntil { approver.oldestPending != nil }
        let pending = approver.oldestPending
        #expect(pending?.toolName == "Write a file")
        if let pending {
            approver.approve(pending)
        }

        await waitUntil { await transport.permissionResponses.count == 1 }
        let response = await transport.permissionResponses.first
        #expect(response?.correlationID == "corr-1")
        #expect(response?.approved == true)
        let request = await transport.turnRequests.first
        #expect(response?.request == request)

        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()
    }

    @Test("Denying a permission request sends a negative response")
    func denialSendsDenial() async {
        let transport = FakeGnosticTransport()
        let approver = MainActorToolApprover()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport, approver: approver))

        viewModel.send("do it")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.permission(GnosticTurnPermissionRequest(
            correlationID: "corr-2",
            toolCallID: "call-2",
            title: "Write a file",
            status: .pending
        )))

        await waitUntil { approver.oldestPending != nil }
        if let pending = approver.oldestPending {
            approver.deny(pending)
        }

        await waitUntil { await transport.permissionResponses.count == 1 }
        #expect(await transport.permissionResponses.first?.approved == false)

        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()
    }

    @Test("A failed permission publish becomes a terminal turn error")
    func permissionPublishFailureSurfacesError() async {
        let transport = FakeGnosticTransport()
        await transport.failNextPermission(.turnUnavailable("permission channel closed"))
        let approver = MainActorToolApprover()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport, approver: approver))

        viewModel.send("do it")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.permission(GnosticTurnPermissionRequest(
            correlationID: "corr-failure",
            toolCallID: "call-failure",
            title: "Write a file",
            status: .pending
        )))

        await waitUntil { approver.oldestPending != nil }
        if let pending = approver.oldestPending {
            approver.approve(pending)
        }
        await viewModel.awaitSendCompletion()

        let errorRow = viewModel.transcript.last { item in
            if case .error = item { return true }
            return false
        }
        guard case let .error(_, message, _) = errorRow else {
            Issue.record("expected a permission publish error row")
            return
        }
        #expect(message.contains("permission channel closed"))
        #expect(viewModel.isSending == false)
    }

    @Test("An unexpected source-stream end becomes a terminal turn error")
    func unexpectedStreamEndSurfacesError() async {
        let transport = FakeGnosticTransport()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport))

        viewModel.send("hello")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.dropTurnStreams()
        await viewModel.awaitSendCompletion()

        let errorRow = viewModel.transcript.last { item in
            if case .error = item { return true }
            return false
        }
        guard case let .error(_, message, _) = errorRow else {
            Issue.record("expected an unexpected-stream error row")
            return
        }
        #expect(message == "The Network Turn ended before it completed.")
        #expect(viewModel.isSending == false)
    }

    @Test("A resolved permission state is not re-presented for approval")
    func resolvedPermissionIgnored() async {
        let transport = FakeGnosticTransport()
        let approver = MainActorToolApprover()
        let viewModel = makeViewModel(backend: makeBackend(transport: transport, approver: approver))

        viewModel.send("do it")
        await waitUntil { await transport.turnRequests.count == 1 }
        await transport.emitTurn(.permission(GnosticTurnPermissionRequest(
            correlationID: "corr-3",
            toolCallID: "call-3",
            title: "Write a file",
            status: .selected
        )))
        await transport.emitTurn(.completed)
        await viewModel.awaitSendCompletion()

        #expect(approver.pending.isEmpty)
        #expect(await transport.permissionResponses.isEmpty)
    }
}
