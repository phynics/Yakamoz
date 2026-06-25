import Foundation
import Logging
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKShared
import PositronicKit
import SwiftData

/// Builds the `any LLMServiceProtocol` that `YakamozRuntime` hands to `PositronicKit`.
///
/// Defaults to the real `PKOpenAIProvider`-registered `LLMService`. Tests substitute a factory
/// that returns a mock (e.g. `PKTestSupport.MockLLMService`) so no network call ever happens
/// during `make test`.
public typealias LLMServiceFactory = @Sendable (LLMConfiguration) -> any LLMServiceProtocol

/// The default factory used in production: registers supported provider client factories and
/// constructs a real `LLMService` from the given configuration.
public func defaultLLMServiceFactory(configuration: LLMConfiguration) -> any LLMServiceProtocol {
    PKOpenAIProvider.register()
    PKOpenRouterProvider.register()
    PKOllamaProvider.register()
    return LLMService(configuration: configuration)
}

/// App-facing mirror of `PKShared.HealthStatus`.
///
/// The `Yakamoz` app target links only `YakamozCore` (see `project.yml`); it must never
/// name a `PositronicKit`/`PKShared` type directly, or the optimized `test` build's
/// linker pass fails with undefined symbols for that framework's metadata (the app
/// binary never embeds it). This boundary type lets `SettingsView` show a health badge
/// without importing `PKShared`.
public enum AppHealthStatus: String, Sendable, Equatable {
    case ok
    case degraded
    case down

    init(_ status: HealthStatus) {
        switch status {
        case .ok: self = .ok
        case .degraded: self = .degraded
        case .down: self = .down
        }
    }
}

/// The single composition root for Yakamoz's runtime: wires SwiftData-backed persistence
/// (`YakamozStores`), turn inspection (`SwiftDataTurnInspector`), provider settings/secrets, and
/// the `PositronicKit` facade together behind one `actor`.
///
/// `llmServiceFactory` is the seam that keeps this testable without touching the network: pass a
/// factory that returns `PKTestSupport.MockLLMService` (or any other `LLMServiceProtocol`) instead
/// of relying on the default `PKOpenAIProvider`/`LLMService` wiring.
public actor YakamozRuntime: ChatRunning {
    public let kit: PositronicKit
    public let stores: YakamozStores
    public let inspector: SwiftDataTurnInspector

    private static let logger = Logger(label: "me.atkn.Yakamoz.runtime")

    private let settingsSnapshotProvider: @MainActor () -> ProviderSettingsSnapshot
    private let secrets: any SecretStoring
    private let llmServiceFactory: LLMServiceFactory

    /// Per-timeline prompt-history/journal-diff state (YAK-16), held once for this runtime's
    /// lifetime and injected into every `PositronicKit` instance `makeConfiguredKit()` builds.
    ///
    /// `run(...)` resolves fresh provider settings/API key on every send, so it calls
    /// `makeConfiguredKit()` which constructs a brand-new `PositronicKit` value per send. If
    /// each of those got `PositronicKit`'s default fresh registry, the inspection-turn-index
    /// counter and prompt-diff baseline would reset every send — the first round-trip of every
    /// send would collide with turn index 0 of the previous send's first round-trip, silently
    /// overwriting its persisted `TurnInspectionModel` row. Holding one registry here and
    /// passing it into every `makeKit` call keeps that state alive across sends.
    private let promptHistoryRegistry = TimelinePromptHistoryRegistry()

    @MainActor
    public init(
        modelContainer: ModelContainer,
        settings: ProviderSettings,
        secrets: any SecretStoring,
        llmServiceFactory: @escaping LLMServiceFactory = defaultLLMServiceFactory
    ) throws {
        stores = YakamozStores(modelContainer: modelContainer)
        inspector = SwiftDataTurnInspector(modelContainer: modelContainer)
        settingsSnapshotProvider = { @MainActor in settings.snapshot }
        self.secrets = secrets
        self.llmServiceFactory = llmServiceFactory

        let settingsSnapshot = settings.snapshot
        kit = try Self.makeKit(
            stores: stores,
            inspector: inspector,
            settingsSnapshot: settingsSnapshot,
            apiKey: ProviderSettings.storedAPIKey(for: settingsSnapshot.preset, secrets: secrets),
            llmServiceFactory: llmServiceFactory,
            promptHistoryRegistry: promptHistoryRegistry
        )
    }

    // MARK: - Tools

    /// All demo tools (`calculator`, `current_datetime`) plus the folder-workspace
    /// filesystem tools (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`,
    /// jailed to `workspaceRoot`), filtered down to `enabledToolIds`. Pass the result to
    /// `ChatViewModel`'s `tools:` parameter so a conversation only offers the tools the
    /// user actually enabled for it.
    ///
    /// `workspaceRoot` is `nil` when the conversation has no attached folder workspace —
    /// in that case only demo tools are offered, even if filesystem tool ids happen to be
    /// present in `enabledToolIds` (there is nothing to jail them to).
    public nonisolated func resolveTools(enabledToolIds: [String], workspaceRoot: URL?) -> [AnyTool] {
        var available: [AnyTool] = [
            CalculatorTool().toAnyTool(),
            CurrentDateTimeTool().toAnyTool(),
        ]

        if let workspaceRoot {
            let root = workspaceRoot.path
            available.append(contentsOf: [
                ReadFileTool(currentDirectory: root, jailRoot: root).toAnyTool(),
                ListDirectoryTool(currentDirectory: root, jailRoot: root).toAnyTool(),
                FindFileTool(currentDirectory: root, jailRoot: root).toAnyTool(),
                SearchFilesTool(currentDirectory: root, jailRoot: root).toAnyTool(),
                SearchFileContentTool(currentDirectory: root, jailRoot: root).toAnyTool(),
                ChangeDirectoryTool(currentPath: root, root: root, onChange: { _ in }).toAnyTool(),
            ])
        }

        let enabled = Set(enabledToolIds)
        guard !enabled.isEmpty else { return available }
        return available.filter { enabled.contains($0.id) }
    }

    /// Builds a `WorkspacePresentation` for the given folder-backed `WorkspaceModel`, for
    /// the Workspace inspector tab. Returns `nil` if the folder no longer exists.
    public nonisolated func makeWorkspacePresentation(folderPath: String, displayName: String) async -> WorkspacePresentation? {
        let rootURL = URL(fileURLWithPath: folderPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let fsWorkspace = FileSystemWorkspace(rootURL: rootURL, displayName: displayName)
        return await WorkspacePresentation.build(from: fsWorkspace, displayName: displayName)
    }

    /// Delegates to the underlying LLM service's health check exactly once per call.
    public func healthCheck() async -> HealthStatus {
        do {
            let llmService = try await makeConfiguredLLMService()
            return await llmService.checkHealth()
        } catch {
            return .down
        }
    }

    /// `healthCheck()` mapped to the app-safe `AppHealthStatus`, for callers (the
    /// `Yakamoz` app target) that must not name `PKShared.HealthStatus` directly.
    public func appHealthCheck() async -> AppHealthStatus {
        AppHealthStatus(await healthCheck())
    }

    /// Builds a `ChatViewModel` for the given conversation/timeline id, boxing this
    /// runtime's `PositronicKit` facade into `any ChatRunning` entirely inside
    /// `YakamozCore` so the app target never needs to name the `PositronicKit` type
    /// (which it does not link directly — see `AppHealthStatus`'s doc comment).
    @MainActor
    public func makeChatViewModel(
        timelineId: UUID,
        agentInstanceId: UUID? = nil,
        systemInstructions: String? = nil,
        enabledToolIds: [String] = [],
        workspaceRoot: URL? = nil,
        typedReplyEnabled: Bool = false,
        autonomousFollowUpEnabled: Bool = false
    ) async -> ChatViewModel {
        let turnInspector = inspector
        let tools = resolveTools(enabledToolIds: enabledToolIds, workspaceRoot: workspaceRoot)
        let loadedTranscript = (try? await loadTranscript(for: timelineId)) ?? .empty

        // The autonomous-follow-up plugin is opt-in per conversation. When enabled, the
        // conversation runs through a runner that injects the plugin into the per-turn kit
        // (the base `run` path never adds plugins). Its per-send guard is reset by the view
        // model via `onBeginUserSend` before each user message.
        let runner: any ChatRunning
        let onBeginUserSend: (@MainActor @Sendable () async -> Void)?
        if autonomousFollowUpEnabled {
            let plugin = AutonomousFollowUpPlugin()
            runner = FollowUpRunner(runtime: self, plugin: plugin)
            onBeginUserSend = { await plugin.beginUserSend() }
        } else {
            runner = self
            onBeginUserSend = nil
        }

        return ChatViewModel(
            timelineId: timelineId,
            runner: runner,
            inspector: turnInspector,
            agentInstanceId: agentInstanceId,
            tools: tools,
            systemInstructions: systemInstructions,
            structuredOutput: typedReplyEnabled ? TypedReply.request() : nil,
            typedReplyEnabled: typedReplyEnabled,
            onBeginUserSend: onBeginUserSend,
            initialTranscript: loadedTranscript.transcript
        )
    }

    /// Builds the per-turn kit with the autonomous-follow-up `plugin` attached. Used by
    /// `FollowUpRunner` so a follow-up-enabled conversation gets the plugin without changing
    /// the shared `run(...)` path that every other conversation uses.
    func makeConfiguredKit(addingPlugin plugin: any ChatTurnPlugin) async throws -> PositronicKit {
        try await makeConfiguredKit().addPlugin(plugin)
    }

    /// Builds an `InspectionViewModel` backed by this runtime's turn inspector, boxing
    /// the `SwiftDataTurnInspector` into `any InspectionReading` inside `YakamozCore` so
    /// the app target never names a `PositronicKit`-linked type (see `AppHealthStatus`).
    @MainActor
    public func makeInspectionViewModel() -> InspectionViewModel {
        InspectionViewModel(repository: inspector)
    }

    /// Creates a new conversation, pairing a `ConversationModel` row with a
    /// PositronicKit `Timeline` sharing the same id (see `ConversationCoordinator`),
    /// without requiring the caller to extract `stores.timelines` itself (that value's
    /// type, `SwiftDataTimelineStore`, is `YakamozCore`-defined and safe, but routing
    /// through here keeps all `Timeline`-touching code in one place).
    @MainActor
    public func createConversation(
        modelContext: ModelContext,
        title: String = "New Chat",
        personaId: UUID? = nil,
        workspaceId: UUID? = nil
    ) async throws -> ConversationModel {
        let coordinator = ConversationCoordinator(modelContext: modelContext, timelineStore: stores.timelines)
        return try await coordinator.createConversation(title: title, personaId: personaId, workspaceId: workspaceId)
    }

    /// ChatRunning conformance that resolves the latest settings and API key on each turn.
    public func run(
        timelineId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        agentInstanceId: UUID? = nil,
        maxTurns: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        promptAssemblyLogger: Logger? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        // Diagnostic (YAK-23): make it visible in logs exactly which tools are advertised to
        // the model for this turn, so "the model never calls a tool" can be told apart from
        // "no tools were offered".
        Self.logger.info("run: advertising \(tools.count) tool(s) to the model: \(tools.map(\.id))")
        let kit = try await makeConfiguredKit()
        return try await kit.run(
            timelineId: timelineId,
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            promptAssemblyLogger: promptAssemblyLogger
        )
    }

    private func currentSettingsSnapshot() async -> ProviderSettingsSnapshot {
        await settingsSnapshotProvider()
    }

    private func makeConfiguredLLMService() async throws -> any LLMServiceProtocol {
        let settings = await currentSettingsSnapshot()
        let key = try ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)
        return llmServiceFactory(settings.configuration(apiKey: key))
    }

    private func makeConfiguredKit() async throws -> PositronicKit {
        let settings = await currentSettingsSnapshot()
        let key = try ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)
        // Fail fast before streaming: a provider that requires a key but has none configured
        // would otherwise issue a request with an empty key and hang with no error surfaced
        // (the assistant bubble spins forever). Throwing here propagates through `run` to
        // `ChatViewModel`'s catch, which shows the message inline.
        if settings.preset.requiresAPIKey, key.isEmpty {
            throw ProviderSettingsError.missingAPIKey
        }
        return Self.makeKit(
            stores: stores,
            inspector: inspector,
            settingsSnapshot: settings,
            apiKey: key,
            llmServiceFactory: llmServiceFactory,
            promptHistoryRegistry: promptHistoryRegistry
        )
    }

    private static func makeKit(
        stores: YakamozStores,
        inspector: SwiftDataTurnInspector,
        settingsSnapshot: ProviderSettingsSnapshot,
        apiKey: String,
        llmServiceFactory: LLMServiceFactory,
        promptHistoryRegistry: TimelinePromptHistoryRegistry
    ) -> PositronicKit {
        let configuration = settingsSnapshot.configuration(apiKey: apiKey)
        let llmService = llmServiceFactory(configuration)
        return PositronicKit(
            llmService: llmService,
            messageStore: stores.messages,
            agentInstanceStore: stores.agents,
            requestOriginStore: stores.origins,
            timelinePersistence: stores.timelines,
            workspacePersistence: stores.workspaces,
            toolPersistence: stores.tools,
            workspaceCreator: FileSystemWorkspaceFactory(),
            sectionProviders: [CurrentTimeSectionProvider()],
            turnInspector: inspector,
            promptHistoryRegistry: promptHistoryRegistry,
            generationParameters: settingsSnapshot.generationParameters
        )
    }

    private struct LoadedTranscript {
        static let empty = LoadedTranscript(transcript: [])

        let transcript: [TranscriptItem]
    }

    private func loadTranscript(for timelineId: UUID) async throws -> LoadedTranscript {
        let messages = try await stores.messages.fetchMessages(for: timelineId)
        return Self.transcriptItems(from: messages)
    }

    private static func transcriptItems(from messages: [ConversationMessage]) -> LoadedTranscript {
        var assistantTurnIndex = 0
        var nextInspectionTurnIndex = 0
        var transcript: [TranscriptItem] = []
        var pendingAssistantMessage: ConversationMessage?

        func appendPendingAssistantIfNeeded() {
            guard let message = pendingAssistantMessage else { return }

            var turn = ChatTurnState(turnIndex: assistantTurnIndex)
            turn.inspectionTurnIndex = nextInspectionTurnIndex - 1
            turn.response.reconstructedText = message.content
            turn.response.thinking = message.think ?? ""
            turn.isComplete = true
            transcript.append(.assistant(id: message.id, turn: turn))

            assistantTurnIndex += 1
            pendingAssistantMessage = nil
        }

        for message in messages {
            switch message.messageRole {
            case .user:
                appendPendingAssistantIfNeeded()
                transcript.append(.user(id: message.id, text: message.content, timestamp: message.timestamp))
            case .assistant:
                pendingAssistantMessage = message
                nextInspectionTurnIndex += 1
            case .tool, .system, .summary:
                continue
            }
        }

        appendPendingAssistantIfNeeded()

        return LoadedTranscript(transcript: transcript)
    }
}

/// A `ChatRunning` adapter that routes each turn through a plugin-augmented kit.
///
/// `YakamozRuntime.run(...)` deliberately never attaches `ChatTurnPlugin`s (every
/// conversation shares the same runtime). Conversations that opt into autonomous follow-up
/// run through this adapter instead, which rebuilds the per-turn kit with the conversation's
/// own `AutonomousFollowUpPlugin` attached. The runtime stays the single composition root;
/// this only changes which kit a single conversation's turns execute on.
struct FollowUpRunner: ChatRunning {
    let runtime: YakamozRuntime
    let plugin: AutonomousFollowUpPlugin

    func run(
        timelineId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        systemInstructions: String?,
        agentInstanceId: UUID?,
        maxTurns: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        promptAssemblyLogger: Logger?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let kit = try await runtime.makeConfiguredKit(addingPlugin: plugin)
        return try await kit.run(
            timelineId: timelineId,
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns,
            generationParameters: generationParameters,
            structuredOutput: structuredOutput,
            promptAssemblyLogger: promptAssemblyLogger
        )
    }
}
