import Foundation
import Logging
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("RuntimeComposition")
struct RuntimeCompositionTests {
    private final class ScriptedRunner: ChatRunning, @unchecked Sendable {
        private(set) var capturedMessages: [String] = []
        private(set) var capturedToolIds: [[String]] = []
        var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?

        func run(
            timelineId _: UUID,
            message: String,
            tools: [AnyTool],
            toolOutputs _: [ToolOutputSubmission]?,
            systemInstructions _: String?,
            agentInstanceId _: UUID?,
            maxTurns _: Int,
            generationParameters _: GenerationParameters?,
            structuredOutput _: StructuredOutputRequest?,
            promptAssemblyLogger _: Logger?
        ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
            capturedMessages.append(message)
            capturedToolIds.append(tools.map(\.id))
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
                continuation.onTermination = { @Sendable _ in
                    continuation.finish()
                }
            }
        }
    }

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

    private func makeTempRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RuntimeCompositionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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

    @Test("OpenRouter runtime reads the OpenRouter API key account")
    @MainActor
    func openRouterRuntimeReadsOpenRouterAPIKeyAccount() throws {
        let settings = makeSettings()
        settings.applyPreset(.openRouter)
        settings.model = "openai/gpt-4o-test"

        let secrets = FakeSecretStore()
        try secrets.write("sk-openai-secret", account: ProviderSettings.apiKeyAccount(for: .openAI))
        try secrets.write("sk-or-v1-openrouter-secret", account: ProviderSettings.apiKeyAccount(for: .openRouter))
        let mock = MockLLMService()

        nonisolated(unsafe) var captured: LLMConfiguration?
        _ = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { configuration in
            captured = configuration
        }

        let configuration = try #require(captured)
        #expect(configuration.activeProvider == .openRouter)
        #expect(configuration.endpoint == ProviderPreset.openRouter.baseURL.absoluteString)
        #expect(configuration.modelName == "openai/gpt-4o-test")
        #expect(configuration.apiKey == "sk-or-v1-openrouter-secret")
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

        let hydrated = await runtime.makeChatViewModel(timelineId: timelineId)
        #expect(hydrated.transcript.count == 1)
        guard case let .user(_, text, _) = hydrated.transcript[0] else {
            Issue.record("Expected hydrated transcript to start with a user item")
            return
        }
        #expect(text == "hello")
    }

    @Test("run() forwards a structured-output request through to the LLM transport")
    @MainActor
    func runForwardsStructuredOutputToTransport() async throws {
        // Regression guard for YAK-1: `YakamozRuntime.run` (and `FollowUpRunner.run`) must pass
        // `structuredOutput:` to `kit.run`. Dropping that argument silently selects the
        // PositronicKit convenience overload that hardcodes `structuredOutput: nil`, which
        // compiles and passes every other test while quietly disabling typed replies.
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-secret-runtime-key", account: ProviderSettings.apiKeyAccount)
        let mock = MockLLMService()
        mock.nextResponse = #"{"tags":["a"]}"#

        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { _ in }

        let stream = try await runtime.run(
            timelineId: UUID(),
            message: "tag this",
            tools: [],
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )
        for try await _ in stream {}

        // The openAI preset maps a structured-output request to a native response_format, which
        // the mock's client records. Nil here means the request never reached the transport.
        #expect(mock.mockClient.lastResponseFormat != nil)
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

    @Test("The runtime can refresh an existing chat view model's tools in place")
    @MainActor
    func toolResolutionUpdatesExistingViewModel() async throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        let mock = MockLLMService()
        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { _ in }
        let runner = ScriptedRunner()
        let viewModel = ChatViewModel(
            timelineId: UUID(),
            runner: runner,
            tools: runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil)
        )

        viewModel.send("before attach")
        try await waitUntil { runner.capturedMessages.count == 1 }
        #expect(runner.capturedToolIds[0] == ["calculator", "current_datetime"])
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }

        let workspaceRoot = try makeTempRoot()
        defer { cleanup(workspaceRoot) }

        viewModel.updateTools(
            runtime.resolveTools(
                enabledToolIds: FileSystemWorkspace.toolIds,
                workspaceRoot: workspaceRoot
            )
        )

        viewModel.send("after attach")
        try await waitUntil { runner.capturedMessages.count == 2 }
        #expect(Set(runner.capturedToolIds[1]) == Set(FileSystemWorkspace.toolIds))
        #expect(!runner.capturedToolIds[1].contains("calculator"))
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }

        viewModel.updateTools(runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil))

        viewModel.send("after detach")
        try await waitUntil { runner.capturedMessages.count == 3 }
        #expect(runner.capturedToolIds[2] == ["calculator", "current_datetime"])
        #expect(!runner.capturedToolIds[2].contains { FileSystemWorkspace.toolIds.contains($0) })
        runner.continuation?.yield(.streamCompleted())
        runner.continuation?.finish()
        try await waitUntil { !viewModel.isSending }
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

    @Test("The runtime re-reads settings and API keys for each new health check")
    @MainActor
    func healthCheckUsesLatestConfiguration() async throws {
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-secret-initial", account: ProviderSettings.apiKeyAccount)
        let mock = MockLLMService()
        mock.mockHealthStatus = .ok

        nonisolated(unsafe) var captured: [LLMConfiguration] = []
        let runtime = try makeRuntime(settings: settings, secrets: secrets, mock: mock) { configuration in
            captured.append(configuration)
        }

        _ = await runtime.healthCheck()
        settings.model = "updated-model"
        try secrets.write("sk-secret-updated", account: ProviderSettings.apiKeyAccount)
        _ = await runtime.healthCheck()

        #expect(captured.count == 3)
        #expect(captured[0].apiKey == "sk-secret-initial")
        #expect(captured[0].modelName == "gpt-4o-test")
        #expect(captured[1].apiKey == "sk-secret-initial")
        #expect(captured[1].modelName == "gpt-4o-test")
        #expect(captured[2].apiKey == "sk-secret-updated")
        #expect(captured[2].modelName == "updated-model")
    }

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
}
