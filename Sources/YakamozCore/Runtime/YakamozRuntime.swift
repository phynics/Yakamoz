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

    private let settingsSnapshotProvider: @MainActor () -> ProviderSettingsSnapshot
    private let secrets: any SecretStoring
    private let llmServiceFactory: LLMServiceFactory

    /// Keeps terminal-workspace `TerminalSession`s alive across timeline switches (YAK-T3/T4).
    /// Shared by `resolveTools` (live agent tools) and any `TerminalWorkspace` parity path so a
    /// command run and a status read see the same shell. Torn down via `terminateAll()` on quit.
    public let terminalRegistry = TerminalSessionRegistry()

    /// Gate consulted before each `terminal_run`. Defaults to `DenyAllApprover()` (default-deny)
    /// so the terminal backend is never an un-gated arbitrary-exec primitive when unwired; the
    /// app injects a concrete UI-bridging approver (YAK-T5).
    private let terminalApprover: any TerminalCommandApproving

    /// Gate consulted by PositronicKit's `ToolRouter` before any tool whose
    /// `requiresPermission` is `true` executes. Defaults to
    /// `DenyAllToolApprovalGate()` (default-deny) so permissioned tools are never an
    /// un-gated primitive when unwired; the app injects a concrete
    /// `MainActorToolApprover` (YAK-31). YAK-47 auto-approves the read-only filesystem
    /// tools (`cat`/`ls`/`find`/`search_files`/`grep`) at this seam in
    /// `resolveTools`, so they never reach this gate; it remains the seam for any
    /// future write tool that opts into `requiresPermission = true`.
    private let toolApprovalGate: any ToolApprovalGate

    @MainActor
    public init(
        modelContainer: ModelContainer,
        settings: ProviderSettings,
        secrets: any SecretStoring,
        llmServiceFactory: @escaping LLMServiceFactory = defaultLLMServiceFactory,
        terminalApprover: any TerminalCommandApproving = DenyAllApprover(),
        toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate()
    ) throws {
        stores = YakamozStores(modelContainer: modelContainer)
        inspector = SwiftDataTurnInspector(modelContainer: modelContainer)
        settingsSnapshotProvider = { @MainActor in settings.snapshot }
        self.secrets = secrets
        self.llmServiceFactory = llmServiceFactory
        self.terminalApprover = terminalApprover
        self.toolApprovalGate = toolApprovalGate

        let settingsSnapshot = settings.snapshot
        kit = try Self.makeKit(
            stores: stores,
            inspector: inspector,
            settingsSnapshot: settingsSnapshot,
            apiKey: ProviderSettings.storedAPIKey(for: settingsSnapshot.preset, secrets: secrets),
            llmServiceFactory: llmServiceFactory,
            toolApprovalGate: toolApprovalGate
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
    public nonisolated func resolveTools(
        enabledToolIds: [String],
        workspaceRoot: URL?,
        terminals: [TerminalToolContext] = []
    ) async -> [AnyTool] {
        let providers = makeToolProviders(workspaceRoot: workspaceRoot, terminals: terminals)
        var available: [AnyTool] = []
        for provider in providers {
            available.append(contentsOf: await provider.resolvedTools())
        }
        let explained = available.map { $0.withExplanationParameter() }
        // YAK-47: auto-approve the read-only filesystem tools (no per-call approval
        // banner) at the registration seam. Write/execute capabilities
        // (`terminal_run`, future write tools) keep their gates — allowlist, not
        // "everything except terminal".
        let autoApproved = ReadOnlyToolApproval.autoApprovedToolIds
        let unpermissioned = explained.map { tool in
            autoApproved.contains(tool.id) ? tool.withoutPermissionRequirement() : tool
        }
        let enabled = Set(enabledToolIds)
        guard !enabled.isEmpty else { return unpermissioned }
        return unpermissioned.filter { enabled.contains($0.id) }
    }

    private nonisolated func makeToolProviders(
        workspaceRoot: URL?,
        terminals: [TerminalToolContext]
    ) -> [any ToolProviding] {
        var providers: [any ToolProviding] = [BuiltInToolProvider()]
        if let workspaceRoot {
            providers.append(FileWorkspaceToolProvider(rootURL: workspaceRoot))
        }
        providers.append(contentsOf: terminals.map {
            TerminalWorkspaceToolProvider(
                terminal: $0,
                registry: terminalRegistry,
                approver: terminalApprover
            )
        })
        return providers
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

    /// Fetches the active provider's advertised model ids using the latest saved settings/API key.
    public func fetchAvailableModels() async throws -> [String] {
        let llmService = try await makeConfiguredLLMService()
        let currentModel = await currentSettingsSnapshot().model
        let available = try await llmService.fetchAvailableModels() ?? []
        return ModelCatalogService().normalize(models: available, currentModel: currentModel)
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
        terminals: [TerminalToolContext] = [],
        typedReplyEnabled: Bool = false,
        autonomousFollowUpEnabled: Bool = false,
        onTimelineStateChange: (@MainActor @Sendable (ConversationTimelineState) async -> Void)? = nil
    ) async -> ChatViewModel {
        let turnInspector = inspector
        let tools = await resolveTools(enabledToolIds: enabledToolIds, workspaceRoot: workspaceRoot, terminals: terminals)
        let loadedTranscript: LoadedTranscript
        do {
            loadedTranscript = try await loadTranscript(for: timelineId)
        } catch {
            Log.chat.warning("failed to load transcript, returning empty", metadata: [
                "timelineID": "\(timelineId)",
            ])
            loadedTranscript = .empty
        }

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
            onTimelineStateChange: onTimelineStateChange,
            initialTranscript: loadedTranscript.transcript
        )
    }

    /// Builds the per-turn kit with the autonomous-follow-up `plugin` attached. Used by
    /// `FollowUpRunner` so a follow-up-enabled conversation gets the plugin without changing
    /// the shared `run(_:)` path that every other conversation uses.
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
    public func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try Self.rejectExternalToolOutputs(request.toolOutputs)
        let kit = try await makeConfiguredKit()
        return try await kit.run(request)
    }

    private static func rejectExternalToolOutputs(_ toolOutputs: [ToolOutputSubmission]?) throws {
        guard toolOutputs?.isEmpty == false else { return }
        throw ToolError.executionFailed("Yakamoz does not accept external tool output submissions.")
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
        return kit.reconfigured(
            llmService: llmServiceFactory(settings.configuration(apiKey: key)),
            generationParameters: settings.generationParameters
        )
    }

    private static func makeKit(
        stores: YakamozStores,
        inspector: SwiftDataTurnInspector,
        settingsSnapshot: ProviderSettingsSnapshot,
        apiKey: String,
        llmServiceFactory: LLMServiceFactory,
        toolApprovalGate: any ToolApprovalGate
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
            generationParameters: settingsSnapshot.generationParameters,
            toolApprovalGate: toolApprovalGate
        )
    }

    private struct LoadedTranscript {
        static let empty = LoadedTranscript(transcript: [])

        let transcript: [TranscriptItem]
    }

    private func loadTranscript(for timelineId: UUID) async throws -> LoadedTranscript {
        let messages = try await stores.messages.fetchMessages(for: timelineId)
        return LoadedTranscript(transcript: Self.transcriptItems(from: messages))
    }

    /// Rebuilds the chat transcript from persisted `ConversationMessage` rows.
    ///
    /// A single logical assistant turn (one user send) can span several LLM round-trips
    /// in the tool-resolution loop, each emitting its own assistant `ConversationMessage`
    /// followed by one `.tool`-role result message per requested call. To match the live
    /// in-session transcript produced by `ChatEventReducer` — which accumulates one
    /// `ChatTurnState` across all round-trips of a send — this rebuild groups consecutive
    /// assistant + `.tool` messages between user messages into a single assistant
    /// `TranscriptItem`, and reconstructs `tools`/`toolOrder` from:
    ///
    /// - each assistant message's `toolCalls` field (the call: id, name, arguments), and
    /// - the matching `.tool`-role result message keyed by `toolCallId` (the result:
    ///   `content` becomes `output`, or `error` when the result is an `"Error: …"` payload).
    ///
    /// Tool traces are accumulated in first-seen order across all assistant messages in
    /// the turn group, mirroring `ChatEventReducer.applyToolCallDelta`/`applyToolStatus`.
    /// The final assistant message in the group supplies `reconstructedText`/`thinking`
    /// (unchanged from the prior reload behavior).
    ///
    /// `internal` so `YakamozTests` can exercise the reconstruction directly with seeded
    /// `ConversationMessage` values (see `TranscriptReloadToolTraceTests`).
    static func transcriptItems(from messages: [ConversationMessage]) -> [TranscriptItem] {
        var assistantTurnIndex = 0
        var nextInspectionTurnIndex = 0
        var transcript: [TranscriptItem] = []

        // Accumulator for the in-flight logical assistant turn: every assistant message
        // in the group (in arrival order, each carrying its own `toolCalls`) plus the
        // `.tool`-role result messages matched by `toolCallId`.
        var pendingLastAssistantMessage: ConversationMessage?
        var pendingToolCallsByAssistant: [[ToolCall]] = []
        var pendingToolResults: [String: ConversationMessage] = [:]

        func appendPendingAssistantIfNeeded() {
            guard let lastMessage = pendingLastAssistantMessage else { return }

            var turn = ChatTurnState(turnIndex: assistantTurnIndex)
            turn.inspectionTurnIndex = nextInspectionTurnIndex - 1
            turn.response.reconstructedText = lastMessage.content
            turn.response.thinking = lastMessage.think ?? ""
            turn.isComplete = true

            // Reconstruct tool calls (mirrors `applyToolCallDelta`): one trace per call,
            // recorded in first-seen order across every assistant message in the group.
            for toolCalls in pendingToolCallsByAssistant {
                for call in toolCalls {
                    if !turn.tools.keys.contains(call.id) {
                        turn.toolOrder.append(call.id)
                    }
                    var trace = turn.tools[call.id] ?? ToolTrace(id: call.id, name: call.name)
                    trace.name = call.name
                    if let argumentsJSON = Self.encodeToolCallArguments(call.arguments) {
                        trace.arguments = argumentsJSON
                    }
                    turn.tools[call.id] = trace
                }
            }

            // Apply tool results (mirrors `applyToolStatus`'s `.success`/`.failed` cases).
            // The persisted `.tool`-role message carries the call's `toolCallId` and a
            // `content` of either the tool's output or `"Error: <message>"` (see
            // `ToolTurnProjector.projectError`); that prefix distinguishes failed runs.
            //
            // Dictionary iteration order is not guaranteed, so results are processed in a
            // deterministic order: matched results first (in `toolOrder`'s existing order,
            // driven by the persisted calls), then orphaned results (no matching persisted
            // call) sorted by timestamp ascending, `id` as tiebreaker, before being
            // appended to `toolOrder`.
            let orderedOrphanResults = pendingToolResults
                .filter { !turn.tools.keys.contains($0.key) }
                .sorted { lhs, rhs in
                    if lhs.value.timestamp != rhs.value.timestamp {
                        return lhs.value.timestamp < rhs.value.timestamp
                    }
                    return lhs.value.id.uuidString < rhs.value.id.uuidString
                }
                .map(\.key)

            for callId in turn.toolOrder {
                guard var trace = turn.tools[callId], let resultMessage = pendingToolResults[callId] else { continue }
                let content = resultMessage.content
                let isFailure = content.hasPrefix(Self.toolErrorPrefix)
                if isFailure {
                    trace.state = .failed
                    trace.error = String(content.dropFirst(Self.toolErrorPrefix.count))
                } else {
                    trace.state = .succeeded
                    trace.output = content
                }
                turn.tools[callId] = trace
            }

            for callId in orderedOrphanResults {
                guard let resultMessage = pendingToolResults[callId] else { continue }
                let content = resultMessage.content
                let isFailure = content.hasPrefix(Self.toolErrorPrefix)
                // A result without a persisted call: surface it for parity, naming
                // the trace by its call id so the UI still renders a badge.
                if !turn.toolOrder.contains(callId) {
                    turn.toolOrder.append(callId)
                }
                let trace = ToolTrace(
                    id: callId,
                    name: callId,
                    state: isFailure ? .failed : .succeeded,
                    output: isFailure ? nil : content,
                    error: isFailure ? String(content.dropFirst(Self.toolErrorPrefix.count)) : nil
                )
                turn.tools[callId] = trace
            }

            transcript.append(.assistant(id: lastMessage.id, turn: turn))

            assistantTurnIndex += 1
            pendingLastAssistantMessage = nil
            pendingToolCallsByAssistant = []
            pendingToolResults = [:]
        }

        for message in messages {
            switch message.messageRole {
            case .user:
                appendPendingAssistantIfNeeded()
                transcript.append(.user(id: message.id, text: message.content, timestamp: message.timestamp))
            case .assistant:
                let toolCalls = Self.decodeToolCalls(message.toolCalls)
                pendingLastAssistantMessage = message
                if !toolCalls.isEmpty { pendingToolCallsByAssistant.append(toolCalls) }
                nextInspectionTurnIndex += 1
            case .tool:
                if let callId = message.toolCallId {
                    pendingToolResults[callId] = message
                }
            case .system, .summary:
                continue
            }
        }

        appendPendingAssistantIfNeeded()

        return transcript
    }

    /// Decodes a persisted assistant message's `toolCalls` JSON string into `[ToolCall]`.
    /// Returns an empty array when the field is missing/`"[]"`/undecodable, mirroring
    /// `ConversationMessage.toMessage()`'s tolerant decoding.
    private static func decodeToolCalls(_ toolCallsJSON: String) -> [ToolCall] {
        guard let data = toolCallsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
    }

    /// Encodes a `ToolCall`'s arguments dictionary to a JSON string for `ToolTrace.arguments`,
    /// matching the shape the live reducer produces (the final tool-call delta carries the
    /// full args JSON). Returns `nil` when the dictionary is empty or fails to encode.
    private static func encodeToolCallArguments(_ arguments: [String: AnyCodable]) -> String? {
        guard !arguments.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Prefix `ToolTurnProjector` prepends to a tool's persisted `.tool`-role message
    /// `content` when the tool failed (`"Error: <message>"`). Used to distinguish
    /// succeeded from failed tool results on reload.
    private static let toolErrorPrefix = "Error: "
}

private struct BuiltInToolProvider: ToolProviding {
    let toolProvenance: ToolProvenance = .global
    func provideTools() async -> [AnyTool] {
        [
            CalculatorTool().toAnyTool(),
            CurrentDateTimeTool().toAnyTool(),
        ]
    }
}

private struct FileWorkspaceToolProvider: ToolProviding {
    let rootURL: URL
    let workspaceID: UUID

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.workspaceID = UUID()
    }

    var toolProvenance: ToolProvenance {
        .workspace(id: workspaceID, name: rootURL.lastPathComponent)
    }

    func provideTools() async -> [AnyTool] {
        let root = rootURL.path
        return [
            ReadFileTool(currentDirectory: root, jailRoot: root).toAnyTool(),
            ListDirectoryTool(currentDirectory: root, jailRoot: root).toAnyTool(),
            FindFileTool(currentDirectory: root, jailRoot: root).toAnyTool(),
            SearchFilesTool(currentDirectory: root, jailRoot: root).toAnyTool(),
            SearchFileContentTool(currentDirectory: root, jailRoot: root).toAnyTool(),
            ChangeDirectoryTool(currentPath: root, root: root, onChange: { _ in }).toAnyTool(),
        ]
    }
}

private struct TerminalWorkspaceToolProvider: ToolProviding {
    let terminal: TerminalToolContext
    let registry: TerminalSessionRegistry
    let approver: any TerminalCommandApproving

    var toolProvenance: ToolProvenance {
        .terminal(id: terminal.workspaceId, name: terminal.rootURL.lastPathComponent)
    }

    func provideTools() async -> [AnyTool] {
        [
            TerminalRunTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL, approver: approver).toAnyTool(),
            TerminalReadTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL).toAnyTool(),
            TerminalSendInputTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL).toAnyTool(),
            TerminalInterruptTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL).toAnyTool(),
            TerminalWaitTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL).toAnyTool(),
            TerminalReadOutputTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL).toAnyTool(),
        ]
    }
}

/// A `ChatRunning` adapter that routes each turn through a plugin-augmented kit.
///
/// `YakamozRuntime.run(_:)` deliberately never attaches `ChatTurnPlugin`s (every
/// conversation shares the same runtime). Conversations that opt into autonomous follow-up
/// run through this adapter instead, which rebuilds the per-turn kit with the conversation's
/// own `AutonomousFollowUpPlugin` attached. The runtime stays the single composition root;
/// this only changes which kit a single conversation's turns execute on.
struct FollowUpRunner: ChatRunning {
    let runtime: YakamozRuntime
    let plugin: AutonomousFollowUpPlugin

    func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        guard request.toolOutputs?.isEmpty != false else {
            throw ToolError.executionFailed("Yakamoz does not accept external tool output submissions.")
        }
        let kit = try await runtime.makeConfiguredKit(addingPlugin: plugin)
        return try await kit.run(
            request
        )
    }
}
