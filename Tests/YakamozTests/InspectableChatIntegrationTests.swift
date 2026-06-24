import Foundation
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// End-to-end verification (Task 11): drives a complete two-model-turn conversation —
/// user message → tool call → tool result → assistant response — through a real
/// `YakamozRuntime`/`PositronicKit` stack, with the only seam being an injected
/// `MockLLMService`. No network, no `Task.sleep`-based timing: completion is driven by
/// the scripted stream's own continuation finishing.
///
/// It asserts the full pipeline: exact payloads sent to the provider, journal evolution,
/// the persisted tool trace, the response metadata, the live selection, and — critically —
/// that reopening the same container through a FRESH `SwiftDataTurnInspector` reconstructs
/// the transcript, response text, and tool traces from disk alone.
@Suite("InspectableChatIntegration")
@MainActor
struct InspectableChatIntegrationTests {
    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(YakamozSchema.models)
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> ProviderSettings {
        let suiteName = "InspectableChatIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        return settings
    }

    @Test("A full user→tool→assistant turn is inspectable live and after reopening from disk")
    func fullTurnIsInspectableAndReopenable() async throws {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-e2e-key", account: ProviderSettings.apiKeyAccount)

        // Script the two model turns with no sleeps: invocation 1 emits a calculator tool
        // call (which the engine auto-executes), invocation 2 emits the final answer.
        let mock = MockLLMService()
        mock.mockClient.nextResponses = ["", "Inspection complete"]
        mock.mockClient.nextToolCalls = [
            [MockToolCall(id: "call_calc", name: "calculator", arguments: "{\"expression\": \"2 + 2\"}")],
        ]

        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock }
        )

        let conversation = try await runtime.createConversation(
            modelContext: ModelContext(container),
            title: "E2E"
        )
        let timelineId = conversation.id

        // Attach a runtime workspace to the timeline so the engine's ToolRouter can resolve
        // the per-turn `calculator` tool (a timeline with no attached workspace has no
        // primary workspace to route dynamic tools through). Mirrors how a folder-attached
        // conversation makes demo/filesystem tools routable in the real app.
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yakamoz-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let workspace = WorkspaceReference(
            uri: .timelineWorkspace(timelineId),
            location: .runtime,
            rootPath: workspaceURL.path,
            trustLevel: .full
        )
        let kit = await runtime.kit
        try await kit.timelineManager.hydrateTimeline(id: timelineId)
        let stores = await runtime.stores
        try await stores.workspaces.saveWorkspace(workspace)
        try await kit.timelineManager.attachWorkspace(workspace.id, to: timelineId)

        let viewModel = await runtime.makeChatViewModel(
            timelineId: timelineId,
            enabledToolIds: ["calculator"]
        )

        viewModel.send("Inspect this")
        try await waitUntil { !viewModel.isSending && viewModel.transcript.contains { item in
            if case let .assistant(_, turn) = item { return turn.isComplete }
            return false
        } }

        // --- Live assertions -------------------------------------------------------

        let assistantTurn = try #require(viewModel.transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }.first)
        #expect(assistantTurn.isComplete)
        #expect(assistantTurn.response.reconstructedText == "Inspection complete")

        // The tool trace is present live and succeeded.
        let liveTrace = try #require(assistantTurn.orderedTools.first)
        #expect(liveTrace.name.localizedCaseInsensitiveContains("calc"))
        #expect(liveTrace.state == .succeeded)
        #expect(liveTrace.output == "4")

        // The provider saw the calculator tool definition and our user message.
        let sentTools = try #require(mock.mockClient.lastTools)
        #expect(sentTools.contains { $0.name == "calculator" })
        #expect(mock.mockClient.lastMessages.contains { $0.content.contains("Inspect this") })

        // Two model turns were inspected (turn 0 = pre-tool prompt, turn 1 = post-tool).
        let inspector = await runtime.inspector
        let savedInspections = try await loadInspections(inspector, timelineId: timelineId, upTo: 4)
        #expect(savedInspections.map(\.turnIndex) == [0, 1])
        #expect(savedInspections[0].sentMessages.last?.content == "Inspect this")
        #expect(savedInspections[1].journal.stablePrefixCount > 0)

        // The final assistant response is enriched onto the engine's last inspection turn
        // (turn 1) and projects through the inspection read seam.
        let latestIndex = try #require(try await inspector.latestTurnIndex(conversationId: timelineId))
        #expect(latestIndex == 1)
        let latestPresentation = try #require(
            try await inspector.presentation(conversationId: timelineId, turnIndex: latestIndex)
        )
        #expect(latestPresentation.response?.reconstructedText == "Inspection complete")
        #expect(latestPresentation.response?.tools.first?.status == .success)
        // The view model still tracks a single logical turn for selection/highlighting.
        #expect(viewModel.selectedTurnIndex == 0)
        // But the inspector follows the persisted row that carries the response/tool traces.
        #expect(viewModel.selectedInspectionTurnIndex == 1)

        // The transcript persisted as ConversationMessage rows (user + assistant).
        let messages = try await stores.messages.fetchMessages(for: timelineId)
        #expect(messages.contains { $0.role == "user" && $0.content == "Inspect this" })
        #expect(messages.contains { $0.role == "assistant" && $0.content.contains("Inspection complete") })

        // --- Reopen from a FRESH inspector on the same container -------------------

        let reopenedInspector = SwiftDataTurnInspector(modelContainer: container)
        let reopened = try #require(
            try await reopenedInspector.presentation(conversationId: timelineId, turnIndex: 1)
        )
        #expect(reopened.response?.reconstructedText == "Inspection complete")
        let reopenedTools = try #require(reopened.response?.tools)
        #expect(reopenedTools.first?.status == .success)
        #expect(reopenedTools.first?.output == "4")

        // And the runtime rebuilds the transcript from disk for a fresh view model.
        let reloaded = await runtime.makeChatViewModel(timelineId: timelineId)
        reloaded.selectTurn(0)
        #expect(reloaded.selectedTurnIndex == 0)
        #expect(reloaded.selectedInspectionTurnIndex == 1)
        #expect(reloaded.transcript.contains { item in
            if case let .user(_, text, _) = item { return text == "Inspect this" }
            return false
        })
        #expect(reloaded.transcript.contains { item in
            if case let .assistant(_, turn) = item { return turn.response.reconstructedText == "Inspection complete" }
            return false
        })
    }

    /// Loads each persisted inspection in turn order, stopping at the first missing turn.
    private func loadInspections(
        _ inspector: SwiftDataTurnInspector,
        timelineId: UUID,
        upTo limit: Int
    ) async throws -> [PersistedTurnInspection] {
        var result: [PersistedTurnInspection] = []
        for index in 0 ..< limit {
            guard let inspection = try await inspector.inspection(conversationId: timelineId, turnIndex: index) else {
                break
            }
            result.append(inspection)
        }
        return result
    }
}

/// Polls a `@MainActor` condition, bounded by a timeout so a real failure fails fast
/// instead of hanging. Used only to await effects of the view model's internal send Task;
/// no fixed sleep is baked into the assertions themselves.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
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
