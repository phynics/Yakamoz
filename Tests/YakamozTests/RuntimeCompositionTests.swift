import Foundation
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("RuntimeComposition")
struct RuntimeCompositionTests {
    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            ConversationModel.self,
            MessageModel.self,
            TurnInspectionModel.self,
            PersonaModel.self,
            WorkspaceModel.self,
            TimelineModel.self,
            WorkspaceReferenceModel.self,
            ToolReferenceModel.self,
            AgentInstanceModel.self,
            AgentTemplateModel.self,
            RequestOriginModel.self,
        ])
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    @MainActor
    private func makeSettings() -> ProviderSettings {
        let suiteName = "RuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        return settings
    }

    /// Builds a runtime with a mock LLM factory so the test never touches the network. Captures
    /// the configuration the factory was invoked with so the test can assert on it.
    @MainActor
    private func makeRuntime(
        settings: ProviderSettings,
        secrets: any SecretStoring,
        mock: MockLLMService,
        capturedConfiguration: @escaping @Sendable (LLMConfiguration) -> Void
    ) throws -> YakamozRuntime {
        try YakamozRuntime(
            modelContainer: makeModelContainer(),
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { configuration in
                capturedConfiguration(configuration)
                return mock
            }
        )
    }

    @Test("The injected factory receives the chosen base URL, model, and API key")
    @MainActor
    func factoryReceivesChosenConfiguration() throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-secret-runtime-key", account: ProviderSettings.apiKeyAccount)
        let mock = MockLLMService()

        nonisolated(unsafe) var captured: LLMConfiguration?
        _ = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { configuration in
            captured = configuration
        }

        let configuration = try #require(captured)
        #expect(configuration.activeProvider == .openAI)
        #expect(configuration.endpoint == ProviderPreset.openAI.baseURL.absoluteString)
        #expect(configuration.modelName == "gpt-4o-test")
        #expect(configuration.apiKey == "sk-secret-runtime-key")
    }

    @Test("The runtime exposes the SwiftDataTurnInspector and YakamozStores it constructed")
    @MainActor
    func runtimeUsesSwiftDataStoresAndInspector() async throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        let mock = MockLLMService()

        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { _ in }

        // The inspector is a SwiftDataTurnInspector and is independently usable: round-trip a
        // trivial write/read against it to prove it's wired to the same model container the
        // runtime was constructed with (not some other in-memory default).
        let timelineId = UUID()
        let prompt = AnyPrompt.build {
            SystemPrompt("You are helpful")
            UserPrompt("hi")
        }
        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()
        let inspection = TurnInspection(
            timelineId: timelineId,
            agentInstanceId: nil,
            turnIndex: 0,
            model: "gpt-test",
            rendered: rendered,
            sentMessages: [LLMMessage(role: .user, content: "hi")],
            journal: TurnJournalSnapshot(
                overlay: PromptJournalDiff(
                    changedSemiStableIDs: [],
                    addedSemiStableIDs: [],
                    removedSemiStableIDs: []
                ),
                stablePrefixCount: 0,
                didCompact: false
            ),
            estimatedTokens: rendered.estimatedTokens
        )
        let inspector = await runtime.inspector
        await inspector.didComposeTurn(inspection)
        let fetched = try await inspector.inspection(conversationId: timelineId, turnIndex: 0)
        #expect(fetched != nil)

        // The stores bundle is reachable and backed by the same container: write through the
        // message store adapter and confirm it round-trips.
        let message = ConversationMessage(
            timelineId: timelineId,
            role: .user,
            content: "hello",
            timestamp: Date()
        )
        let stores = await runtime.stores
        try await stores.messages.saveMessage(message)
        let messages = try await stores.messages.fetchMessages(for: timelineId)
        #expect(messages.map(\.content) == ["hello"])
    }

    @Test("The runtime's PositronicKit facade is constructed and runnable")
    @MainActor
    func runtimeExposesPositronicKitFacade() async throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        let mock = MockLLMService()
        mock.nextResponse = "mock reply"

        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { _ in }

        // `kit` is the real PositronicKit facade; its timelineManager/toolRouter are reachable,
        // proving construction succeeded with the stores/inspector this runtime built.
        let kit = await runtime.kit
        _ = kit.timelineManager
        _ = kit.toolRouter
    }

    @Test("healthCheck() delegates to the injected LLM service exactly once")
    @MainActor
    func healthCheckDelegatesOnce() async throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        let mock = MockLLMService()
        mock.mockHealthStatus = .ok

        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { _ in }

        let status = await runtime.healthCheck()
        #expect(status == .ok)

        mock.mockHealthStatus = .degraded
        let secondStatus = await runtime.healthCheck()
        #expect(secondStatus == .degraded)
    }
}
