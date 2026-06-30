import Foundation
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// YAK-33: Validates that the explicit workspaceID security fix in PositronicKit
/// doesn't break existing Yakamoz tool call routing. The unit tests in PositronicKitTests
/// cover the core security invariant directly.
@Suite("ToolWorkspaceSecurity")
@MainActor
struct ToolWorkspaceSecurityTests {
    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(YakamozSchema.models)
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> ProviderSettings {
        let suiteName = "ToolWorkspaceSecurityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        return settings
    }

    @Test("YAK-33: Calculator tool still executes when no workspaceID is specified (regression guard)")
    func calculatorExecutesWithoutWorkspaceID() async throws {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-e2e-key", account: ProviderSettings.apiKeyAccount)

        let mock = MockLLMService()
        mock.mockClient.nextResponses = ["", "The answer is 4"]
        mock.mockClient.nextToolCalls = [
            [MockToolCall(
                id: "call_calc",
                name: "calculator",
                arguments: "{\"expression\": \"2 + 2\"}"
            )],
        ]

        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock }
        )

        let conversation = try await runtime.createConversation(
            modelContext: ModelContext(container),
            title: "YAK-33-regression"
        )
        let timelineId = conversation.id

        let viewModel = await runtime.makeChatViewModel(
            timelineId: timelineId,
            enabledToolIds: ["calculator"]
        )

        viewModel.send("calculate 2+2")
        try await waitUntil { !viewModel.isSending && viewModel.transcript.contains { item in
            if case let .assistant(_, turn) = item { return turn.isComplete }
            return false
        } }

        let assistantTurn = try #require(viewModel.transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }.first)

        #expect(assistantTurn.isComplete)

        let toolTrace = try #require(assistantTurn.orderedTools.first)
        #expect(toolTrace.name.localizedCaseInsensitiveContains("calc"))
        #expect(toolTrace.state == .succeeded)
        #expect(toolTrace.output == "4")
    }
}

// MARK: - Test Utilities

@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition(), Date.now < deadline {
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms poll
    }
    #expect(condition(), "Condition not met within \(timeout) seconds")
}
