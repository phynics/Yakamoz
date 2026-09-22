import Foundation
import Logging
import PKAnthropicProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKContracts
import PositronicKit
import SwiftData

/// Builds the narrow LLM-service seam (`LanguageModel & HealthCheckable`) that
/// `YakamozRuntime` hands to `PositronicKit`.
///
/// Defaults to the real provider-backed `LLMService`. Tests substitute a factory
/// that returns a mock (e.g. `PKTestSupport.MockLLMService`) so no network call ever happens
/// during `make test`.
public typealias LLMServiceFactory = @Sendable (LLMConfiguration) -> any LLMStreamClient & HealthCheckable

/// Model-listing seam: `LLMStreamClient` has no model-catalog operation, but the
/// Settings UI's available-models list needs one. `LLMService` and test doubles
/// declare this conformance.
public protocol YakamozModelService: LLMStreamClient, HealthCheckable {
    func fetchAvailableModels() async throws -> [String]?
}

extension LLMService: YakamozModelService {}

/// The default factory used in production: constructs the configured provider client and wraps it
/// in a real `LLMService`.
public func defaultLLMServiceFactory(configuration: LLMConfiguration) -> any LLMStreamClient & HealthCheckable {
    let client: any LLMClientProtocol = switch configuration.activeProvider {
    case .openAI, .openAICompatible:
        PKOpenAI.makeClient(configuration: configuration)
    case .openRouter:
        PKOpenRouter.makeClient(configuration: configuration)
    case .ollama:
        PKOllama.makeClient(configuration: configuration)
    case .anthropic:
        PKAnthropic.makeClient(configuration: configuration)
    }
    return LLMService(
        configuration: configuration,
        clients: LLMClientSet(primary: client)
    )
}

/// App-facing mirror of PositronicKit's `HealthStatus`.
///
/// The `Yakamoz` app target links only `YakamozCore` (see `project.yml`); it must never
/// name a `PositronicKit` type directly, or the optimized `test` build's
/// linker pass fails with undefined symbols for that framework's metadata (the app
/// binary never embeds it). This boundary type lets `SettingsView` show a health badge
/// without importing PositronicKit.
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

public enum ConversationRunError: Error, Sendable, Equatable, LocalizedError {
    case operatorRequired

    public var errorDescription: String? {
        "Assign an operator first."
    }
}

/// The single composition root for Yakamoz's runtime: wires SwiftData-backed persistence
/// (`YakamozStores`), turn inspection (`SwiftDataPromptInspector`), provider settings/secrets, and
/// the `PositronicKit` facade together behind one `actor`.
///
/// `llmServiceFactory` is the seam that keeps this testable without touching the network: pass a
/// factory that returns `PKTestSupport.MockLLMService` (or any other conformer of the same seam)
/// instead of relying on the default `PKOpenAIProvider`/`LLMService` wiring.
public actor YakamozRuntime: ChatRunning {
    public let kit: PKRuntime
    public let stores: YakamozStores
    public let inspector: SwiftDataPromptInspector

    /// Captured at init so the `@MainActor` `makeChatViewModel` can build a
    /// `ConversationCoordinator` for the post-turn sidecar-results hook without re-
    /// routing a `ModelContext` through the view layer. `ModelContainer` is `Sendable`.
    private nonisolated let modelContainer: ModelContainer

    private let settingsSnapshotProvider: @MainActor () -> ProviderSettingsSnapshot
    private let secrets: any SecretStoring
    private let llmServiceFactory: LLMServiceFactory

    /// Keeps terminal-workspace `TerminalSession`s alive across timeline switches (YAK-T3/T4).
    /// Shared by `resolveTools` (live agent tools) and any `TerminalWorkspace` parity path so a
    /// command run and a status read see the same shell. Torn down via `terminateAll()` on quit.
    public nonisolated let terminalRegistry = TerminalSessionRegistry()

    /// ATW-6: process-wide scheduler that serializes turns contending for the same attached
    /// workspace or the same agent vault. Shared by every `ChatViewModel` this runtime builds so
    /// turns across *all* timelines contend through one FIFO queue per key. Terminal sessions
    /// are not serialized here (spec §5.3) — only the turns.
    public let workspaceTurnScheduler = WorkspaceTurnScheduler()

    /// Gate consulted before each `terminal_run`. Defaults to `DenyAllApprover()` (default-deny)
    /// so the terminal backend is never an un-gated arbitrary-exec primitive when unwired; the
    /// app injects a concrete UI-bridging approver (YAK-T5).
    private nonisolated let terminalApprover: any TerminalCommandApproving

    /// Policy consulted by PositronicKit's `ToolRouter` before any tool whose
    /// `requiresPermission` is `true` executes. Defaults to
    /// `DenyAllToolApprovalPolicy()` (default-deny) so permissioned tools are never an
    /// un-gated primitive when unwired; the app injects a concrete
    /// `MainActorToolApprover` (YAK-31). YAK-47 auto-approves the read-only filesystem
    /// tools (`cat`/`ls`/`find`/`search_files`/`grep`) at this seam in
    /// `resolveTools`, so they never reach this policy; it remains the seam for any
    /// future write tool that opts into `requiresPermission = true`.
    private let toolApprovalPolicy: any ToolApprovalPolicy

    @MainActor
    public init(
        modelContainer: ModelContainer,
        settings: ProviderSettings,
        secrets: any SecretStoring,
        llmServiceFactory: @escaping LLMServiceFactory = defaultLLMServiceFactory,
        terminalApprover: any TerminalCommandApproving = DenyAllApprover(),
        toolApprovalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy()
    ) throws {
        stores = YakamozStores(modelContainer: modelContainer)
        try AgentMigration.seedAndMigrate(modelContext: modelContainer.mainContext)
        inspector = SwiftDataPromptInspector(modelContainer: modelContainer)
        self.modelContainer = modelContainer
        settingsSnapshotProvider = { @MainActor in settings.snapshot }
        self.secrets = secrets
        self.llmServiceFactory = llmServiceFactory
        self.terminalApprover = terminalApprover
        self.toolApprovalPolicy = toolApprovalPolicy

        let settingsSnapshot = settings.snapshot
        kit = try Self.makeKit(
            stores: stores,
            settingsSnapshot: settingsSnapshot,
            apiKey: ProviderSettings.storedAPIKey(for: settingsSnapshot.preset, secrets: secrets),
            llmServiceFactory: llmServiceFactory,
            toolApprovalPolicy: toolApprovalPolicy
        )
    }

    // MARK: - Tools

    /// All demo tools (`calculator`, `current_datetime`) plus the folder-workspace
    /// filesystem tools (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`,
    /// jailed to `folder.rootURL`), filtered down to `enabledToolIds`. Pass the result to
    /// `ChatViewModel`'s `tools:` parameter so a conversation only offers the tools the
    /// user actually enabled for it.
    ///
    /// `folder` is `nil` when the conversation has no attached folder workspace —
    /// in that case only demo tools are offered, even if filesystem tool ids happen to be
    /// present in `enabledToolIds` (there is nothing to jail them to). When non-nil, the
    /// folder's `workspaceID` (the persisted `WorkspaceModel.id`) is carried through to
    /// `FileWorkspaceToolProvider` so the resulting `ToolOrigin.workspace(id:name:)`
    /// is stable across refreshes rather than minted per call (PKPOST-004c).
    public nonisolated func resolveTools(
        enabledToolIds: [String],
        workspaceRoots: [URL],
        terminals: [TerminalToolContext] = []
    ) async -> [AnyTool] {
        // Derive a stable provenance id per root so the same root yields the same id across
        // refreshes (PKPOST-004c). Callers that already hold a persisted `WorkspaceModel.id`
        // (via `FolderToolContext`) should use the `folder:` overload, which carries that
        // id through unchanged rather than re-deriving it.
        let folders = workspaceRoots.map { FolderToolContext(workspaceID: Self.stableWorkspaceID(for: $0), rootURL: $0) }
        let providers = makeToolProviders(folders: folders, terminals: terminals)
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
            autoApproved.contains(tool.callName) ? tool.withoutPermissionRequirement() : tool
        }
        let enabled = Set(enabledToolIds)
        guard !enabled.isEmpty else { return unpermissioned }
        return unpermissioned.filter { enabled.contains($0.callName) }
    }

    /// Compatibility overload for callers that still have a single persisted workspace.
    /// Carries the folder's persisted `workspaceID` through so provenance is stable across
    /// refreshes (PKPOST-004c).
    public nonisolated func resolveTools(
        enabledToolIds: [String],
        folder: FolderToolContext?,
        terminals: [TerminalToolContext] = []
    ) async -> [AnyTool] {
        let folders = folder.map { [$0] } ?? []
        let providers = makeToolProviders(folders: folders, terminals: terminals)
        var available: [AnyTool] = []
        for provider in providers {
            available.append(contentsOf: await provider.resolvedTools())
        }
        let explained = available.map { $0.withExplanationParameter() }
        let autoApproved = ReadOnlyToolApproval.autoApprovedToolIds
        let unpermissioned = explained.map { tool in
            autoApproved.contains(tool.callName) ? tool.withoutPermissionRequirement() : tool
        }
        let enabled = Set(enabledToolIds)
        guard !enabled.isEmpty else { return unpermissioned }
        return unpermissioned.filter { enabled.contains($0.callName) }
    }

    private nonisolated func makeToolProviders(
        folders: [FolderToolContext],
        terminals: [TerminalToolContext]
    ) -> [any ToolSource] {
        var providers: [any ToolSource] = [BuiltInToolProvider()]
        for folder in folders {
            providers.append(FileWorkspaceToolProvider(folder: folder))
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

    /// A deterministic `UUID` derived from a workspace root's resolved path, so the same
    /// root yields the same origin id across `resolveTools` calls. Fills the 16 UUID
    /// bytes by cycling through the path's UTF-8 bytes — a stable, seed-independent
    /// mapping (only needs to be stable per root within a process, not globally unique).
    private static func stableWorkspaceID(for root: URL) -> UUID {
        let bytes = Array(root.standardizedFileURL.resolvingSymlinksInPath().path.utf8)
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in bytes.enumerated() {
            uuidBytes[i % 16] ^= byte
        }
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    /// Computes the sidecar-directive list due for the upcoming turn (SID-1/SID-2).
    /// Pure (no actor state) so it can be unit-tested directly via `@testable import
    /// YakamozCore` without exercising the runtime's network/persistence stack.
    ///
    /// - SID-1 (`title`): cadence-gated by `TitleSidecarSchedule.isDue` against
    ///   `conversationTitle` and `turnsSinceLastTitleDirective`.
    /// - SID-2 (`section_title`): **no schedule** — unconditionally included on every
    ///   sidecar-enabled turn (the optional-response contract keeps it cheap: the model
    ///   returns `null` for the majority of turns that continue the current section).
    ///   `currentSectionTitle` is the *last emitted* annotation's text (fetched by the
    ///   caller via `ConversationCoordinator.fetchLatestSectionTitle`), not a
    ///   `ConversationModel` field — section titles are turn-anchored navigation markers,
    ///   not a single mutable value.
    static func dueSidecarDirectives(
        conversationTitle: String?,
        turnsSinceLastTitleDirective: Int,
        currentSectionTitle: String?
    ) -> [SidecarDirective] {
        var directives: [SidecarDirective] = []
        if TitleSidecarSchedule.isDue(
            hasTitle: conversationTitle != nil,
            turnsSinceLastTitle: turnsSinceLastTitleDirective
        ) {
            directives.append(TitleDirective.make(currentTitle: conversationTitle))
        }
        directives.append(SectionTitleDirective.make(currentSectionTitle: currentSectionTitle))
        return directives
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
    /// `Yakamoz` app target) that must not name a PositronicKit health type directly.
    public func appHealthCheck() async -> AppHealthStatus {
        AppHealthStatus(await healthCheck())
    }

    /// Fetches the active provider's advertised model ids using the latest saved settings/API key.
    public func fetchAvailableModels() async throws -> [String] {
        let llmService = try await makeConfiguredLLMService()
        let currentModel = await currentSettingsSnapshot().model
        // `fetchAvailableModels` is not part of `LLMStreamClient`; both `LLMService`
        // and the test double declare the `YakamozModelService` seam for it.
        guard let service = llmService as? any YakamozModelService else {
            return ModelCatalogService().normalize(models: [], currentModel: currentModel)
        }
        let available = try await service.fetchAvailableModels() ?? []
        return ModelCatalogService().normalize(models: available, currentModel: currentModel)
    }

    /// Builds a `ChatViewModel` for the given conversation/timeline id, boxing this
    /// runtime's `PositronicKit` facade into `any ChatRunning` entirely inside
    /// `YakamozCore` so the app target never needs to name the `PositronicKit` type
    /// (which it does not link directly — see `AppHealthStatus`'s doc comment).
    @MainActor
    public func makeChatViewModel(
        timelineId: UUID,
        systemInstructions: String? = nil,
        enabledToolIds: [String] = [],
        folder: FolderToolContext? = nil,
        workspaceRoots: [URL]? = nil,
        terminals: [TerminalToolContext] = [],
        sidecarDirectivesEnabled: Bool = false,
        conversationTitle: String? = nil,
        turnsSinceLastTitleDirective: Int = 0,
        currentSectionTitle: String? = nil,
        onTimelineStateChange: (@MainActor @Sendable (ConversationTimelineState) async -> Void)? = nil
    ) async -> ChatViewModel {
        let promptInspector = inspector
        let tools = await resolveTools(
            enabledToolIds: enabledToolIds,
            workspaceRoots: workspaceRoots ?? folder.map { [$0.rootURL] } ?? [],
            terminals: terminals
        )
        // ATW-6: compute the turn's workspace/vault contention keys — attached workspace ids
        // plus the operator agent id (the vault is contended between the home timeline and any
        // other timeline run by the same agent). Read from the persisted conversation so the
        // view model's scheduler wiring reflects live attachment state, not a snapshot. A
        // missing conversation yields no keys (no serialization, matching current behavior).
        var turnKeys: [UUID] = []
        var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineId })
        descriptor.fetchLimit = 1
        if let conversation = try? modelContainer.mainContext.fetch(descriptor).first {
            turnKeys = conversation.attachedWorkspaceIds
            if let agentId = conversation.agentId {
                turnKeys.append(agentId)
            }
        }
        let loadedTranscript: LoadedTranscript
        do {
            loadedTranscript = try await loadTranscript(for: timelineId)
        } catch {
            Log.chat.warning("failed to load transcript, returning empty", metadata: [
                "timelineID": "\(timelineId)",
            ])
            loadedTranscript = .empty
        }

        // SID-1/SID-2 post-turn sidecar-results hook. A `ConversationCoordinator` is
        // constructed fresh from the captured container's main context (cheap; the
        // coordinator is a thin value type over `ModelContext`). The closure routes
        // each `SidecarResult` to its handler by `result.name`:
        // - `title` (SID-1) -> `applyTitleDirective` (mutates `ConversationModel`);
        // - `section_title` (SID-2) -> `recordSectionTitleAnnotation` (inserts a
        //   `TimelineAnnotationModel` row anchored to the turn index).
        // Empty `results` (no directive carried the turn, or the model emitted none) is
        // the common path and the closure no-ops through it. Errors from the handlers
        // are swallowed here: the response has already been persisted; a side-effect
        // write failure is not worth surfacing as a turn error (matches the handlers'
        // own silent-no-op for missing conversations).
        let conversationCoordinator = ConversationCoordinator(
            modelContext: modelContainer.mainContext,
            timelineStore: stores.runtime
        )
        let sidecarTimelineId = timelineId
        let onSidecarResults: (@MainActor @Sendable (Int, [SidecarResult]) async -> Void) = { turnIndex, results in
            for result in results {
                switch result.name {
                case TitleDirective.name:
                    try? await conversationCoordinator.applyTitleDirective(
                        conversationId: sidecarTimelineId,
                        result: result
                    )
                case SectionTitleDirective.name:
                    try? conversationCoordinator.recordSectionTitleAnnotation(
                        conversationId: sidecarTimelineId,
                        turnIndex: turnIndex,
                        result: result
                    )
                default:
                    break
                }
            }
        }

        return ChatViewModel(
            timelineId: timelineId,
            runner: self,
            inspector: promptInspector,
            tools: tools,
            systemInstructions: systemInstructions,
            sidecars: sidecarDirectivesEnabled
                ? Self.dueSidecarDirectives(
                    conversationTitle: conversationTitle,
                    turnsSinceLastTitleDirective: turnsSinceLastTitleDirective,
                    currentSectionTitle: currentSectionTitle
                )
                : [],
            onTimelineStateChange: onTimelineStateChange,
            onSidecarResults: onSidecarResults,
            initialTranscript: loadedTranscript.transcript,
            turnScheduler: workspaceTurnScheduler,
            turnKeys: turnKeys
        )
    }

    /// Builds an `InspectionViewModel` backed by this runtime's turn inspector, boxing
    /// the `SwiftDataPromptInspector` into `any InspectionReading` inside `YakamozCore` so
    /// the app target never names a `PositronicKit`-linked type (see `AppHealthStatus`).
    @MainActor
    public func makeInspectionViewModel() -> InspectionViewModel {
        InspectionViewModel(repository: inspector)
    }

    /// Returns the conversation's most recent section-title annotation text (SID-2), or
    /// `nil` when none exists yet. Used by `ChatView` to feed the upcoming turn's
    /// `section_title` directive's "current section" context. Surfaced on the runtime
    /// (rather than having the app target construct a `ConversationCoordinator` itself)
    /// so the app target never names `ThreadPersistenceProtocol` — a PositronicKit
    /// type the app target must not import per the architecture boundary. Swallows
    /// SwiftData read errors (returns `nil`) since a missing read degrades gracefully to
    /// "no section has been marked yet" in the directive's instruction.
    @MainActor
    public func fetchCurrentSectionTitle(conversationId: UUID) async -> String? {
        let coordinator = ConversationCoordinator(
            modelContext: modelContainer.mainContext,
            timelineStore: stores.runtime
        )
        return try? coordinator.fetchLatestSectionTitle(conversationId: conversationId)
    }

    /// Returns the conversation's section-title annotations (SID-2) as app-target-safe
    /// `SectionAnnotationView`s for the navigation jump bar, sorted by turn index
    /// (oldest first, matching timeline reading order). Empty when the conversation has
    /// produced no accepted section titles yet. Surfaced on the runtime so the app
    /// target never names SwiftData `@Model` types or `ConversationCoordinator`
    /// collaborators directly. Swallows SwiftData read errors (returns `[]`) so a
    /// read failure degrades gracefully to a hidden bar.
    @MainActor
    public func fetchSectionAnnotations(conversationId: UUID) async -> [SectionAnnotationView] {
        let coordinator = ConversationCoordinator(
            modelContext: modelContainer.mainContext,
            timelineStore: stores.runtime
        )
        guard let annotations = try? coordinator.fetchSectionAnnotations(conversationId: conversationId) else {
            return []
        }
        return annotations.sectionAnnotationViews
    }

    /// Creates a new conversation, pairing a `ConversationModel` row with a
    /// PositronicKit `Timeline` sharing the same id (see `ConversationCoordinator`),
    /// without requiring the caller to extract `stores.runtime` itself (that value's
    /// type, `SwiftDataTimelineStore`, is `YakamozCore`-defined and safe, but routing
    /// through here keeps all `Timeline`-touching code in one place).
    @MainActor
    public func createConversation(
        modelContext: ModelContext,
        title: String = "New Conversation",
        agentId: UUID? = nil,
        attachedWorkspaceIds: [UUID] = [],
        isHomeTimeline: Bool = false
    ) async throws -> ConversationModel {
        let coordinator = ConversationCoordinator(modelContext: modelContext, timelineStore: stores.runtime)
        return try await coordinator.createConversation(title: title, agentId: agentId, attachedWorkspaceIds: attachedWorkspaceIds, isHomeTimeline: isHomeTimeline)
    }

    /// Creates a new `AgentModel` and initializes its vault directory (ATW-8: "New Agent"
    /// sidebar action). The vault path is deterministic from the agent's id
    /// (`AgentVaultFactory.vaultRoot(for:)`), matching how `AgentVaultPromptSectionProvider`
    /// and `homeTimeline(for:modelContext:)` resolve it later.
    @MainActor
    public func createAgent(
        modelContext: ModelContext,
        name: String = "New Operator",
        instructions: String = ""
    ) throws -> AgentModel {
        let factory = AgentVaultFactory()
        let agent = AgentModel(name: name, instructions: instructions, vaultPath: "")
        agent.vaultPath = factory.vaultRoot(for: agent.id).path
        try factory.createVault(for: agent)
        modelContext.insert(agent)
        try modelContext.save()
        return agent
    }

    @MainActor
    public func setOperator(modelContext: ModelContext, conversationId: UUID, agentId: UUID?) async throws {
        let coordinator = ConversationCoordinator(modelContext: modelContext, timelineStore: stores.runtime)
        try await coordinator.setOperator(conversationId: conversationId, agentId: agentId)
    }

    /// Returns the agent's home timeline, creating it only when its Chat tab is first opened.
    @MainActor
    public func homeTimeline(for agentId: UUID, modelContext: ModelContext) async throws -> ConversationModel {
        let coordinator = ConversationCoordinator(modelContext: modelContext, timelineStore: stores.runtime)
        return try await coordinator.homeTimeline(for: agentId)
    }

    /// Deletes an agent after the view has collected its destructive-action confirmation.
    /// The cascade removes the home timeline and vault while retaining other timelines as
    /// unassigned conversations.
    @MainActor
    public func deleteAgent(id: UUID, modelContext: ModelContext) async throws {
        let coordinator = ConversationCoordinator(modelContext: modelContext, timelineStore: stores.runtime)
        try await coordinator.deleteAgent(id: id)
    }

    /// ChatRunning conformance that resolves the latest settings and API key on each turn.
    ///
    /// PositronicKit 6 exposes managed execution as
    /// `TimelineHandle.startTurn(_:systemInstructions:options:) -> TurnHandle`; its
    /// non-throwing `events()` stream is returned directly over the seam.
    public func run(_ request: ChatRunRequest) async throws -> AsyncStream<TurnEvent> {
        let timelineID = request.timelineID
        let hasOperator = try await MainActor.run {
            var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineID })
            descriptor.fetchLimit = 1
            return try modelContainer.mainContext.fetch(descriptor).first?.agentId != nil
        }
        guard hasOperator else { throw ConversationRunError.operatorRequired }
        try Self.rejectExternalToolOutputs(request.toolOutputs)
        let kit = try await makeConfiguredKit()
        let turn = try await kit.timelines.open(timelineID).startTurn(
            request.message,
            systemInstructions: request.systemInstructions,
            options: TurnOptions(
                requestID: request.requestID,
                tools: request.tools,
                toolOutputs: request.toolOutputs,
                maxModelRounds: request.maxModelRounds,
                generationParameters: request.generationParameters,
                structuredOutput: request.structuredOutput,
                sidecars: request.sidecars
            )
        )
        return turn.events()
    }

    private static func rejectExternalToolOutputs(_ toolOutputs: [ToolOutputSubmission]?) throws {
        guard toolOutputs?.isEmpty == false else { return }
        throw ToolError.executionFailed("Yakamoz does not accept external tool output submissions.")
    }

    private func currentSettingsSnapshot() async -> ProviderSettingsSnapshot {
        await settingsSnapshotProvider()
    }

    private func makeConfiguredLLMService() async throws -> any LLMStreamClient & HealthCheckable {
        let settings = await currentSettingsSnapshot()
        let key = try ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)
        return llmServiceFactory(settings.configuration(apiKey: key))
    }

    private func makeConfiguredKit() async throws -> PKRuntime {
        let settings = await currentSettingsSnapshot()
        let key = try ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)
        // Fail fast before streaming: a provider that requires a key but has none configured
        // would otherwise issue a request with an empty key and hang with no error surfaced
        // (the assistant bubble spins forever). Throwing here propagates through `run` to
        // `ChatViewModel`'s catch, which shows the message inline.
        if settings.preset.requiresAPIKey, key.isEmpty {
            throw ProviderSettingsError.missingAPIKey
        }
        return kit.replacingLanguageModel(
            llmServiceFactory(settings.configuration(apiKey: key)),
            generationParameters: settings.generationParameters
        )
    }

    private static func makeKit(
        stores: YakamozStores,
        settingsSnapshot: ProviderSettingsSnapshot,
        apiKey: String,
        llmServiceFactory: LLMServiceFactory,
        toolApprovalPolicy: any ToolApprovalPolicy
    ) -> PKRuntime {
        let llmConfiguration = settingsSnapshot.configuration(apiKey: apiKey)
        let llmService = llmServiceFactory(llmConfiguration)
        return PKRuntime(
            configuration: .init(
                languageModel: llmService,
                persistence: .init(
                    runtimeRepository: stores.runtime,
                    workspacePersistence: stores.workspaces,
                    toolPersistence: stores.tools,
                    agentStore: stores.agents,
                    requestOriginStore: stores.origins
                ),
                runtime: .init(
                    workspaceCreator: FileSystemWorkspaceFactory(),
                    customization: RuntimeCustomization(
                        turnContextSource: CurrentTimeContextSource()
                    ),
                    toolApprovalPolicy: toolApprovalPolicy
                ),
                generationParameters: settingsSnapshot.generationParameters
            )
        )
    }

    private struct LoadedTranscript {
        static let empty = LoadedTranscript(transcript: [])

        let transcript: [TranscriptItem]
    }

    private func loadTranscript(for timelineId: UUID) async throws -> LoadedTranscript {
        let messages = try await stores.runtime.fetchMessages(for: timelineId)
        return LoadedTranscript(transcript: Self.transcriptItems(from: messages))
    }

    /// Rebuilds the chat transcript from persisted `ThreadMessage` rows.
    ///
    /// A single logical assistant turn (one user send) can span several LLM round-trips
    /// in the tool-resolution loop, each emitting its own assistant `ThreadMessage`
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
    /// `ThreadMessage` values (see `TranscriptReloadToolTraceTests`).
    static func transcriptItems(from messages: [TimelineMessage]) -> [TranscriptItem] {
        var assistantTurnIndex = 0
        var nextInspectionTurnIndex = 0
        var transcript: [TranscriptItem] = []

        // Accumulator for the in-flight logical assistant turn: every assistant message
        // in the group (in arrival order, each carrying its own `toolCalls`) plus the
        // `.tool`-role result messages matched by `toolCallId`.
        var pendingLastAssistantMessage: TimelineMessage?
        var pendingToolCallsByAssistant: [[ToolCall]] = []
        var pendingToolResults: [String: TimelineMessage] = [:]

        func appendPendingAssistantIfNeeded() {
            guard let lastMessage = pendingLastAssistantMessage else { return }

            var turn = ChatTurnState(turnIndex: assistantTurnIndex)
            turn.inspectionTurnIndex = nextInspectionTurnIndex - 1
            turn.response.reconstructedText = lastMessage.content
            turn.response.thinking = lastMessage.reasoning ?? ""
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
                if let callId = message.toolCallID {
                    pendingToolResults[callId] = message
                }
            case .system:
                // ATW-3: app-generated info rows (e.g. operator-swap handoff markers)
                // render as their own distinct transcript item, never folded into an
                // assistant/user bubble.
                appendPendingAssistantIfNeeded()
                transcript.append(.system(id: message.id, text: message.content, timestamp: message.timestamp))
            case .summary:
                continue
            }
        }

        appendPendingAssistantIfNeeded()

        return transcript
    }

    /// Decodes a persisted assistant message's `toolCalls` JSON string into `[ToolCall]`.
    /// Returns an empty array when the field is missing/`"[]"`/undecodable, mirroring
    /// `ThreadMessage.toMessage()`'s tolerant decoding.
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

private struct BuiltInToolProvider: ToolSource {
    let toolOrigin: ToolOrigin = .global
    func tools() async -> [AnyTool] {
        [
            AnyTool(CalculatorTool()),
            AnyTool(CurrentDateTimeTool()),
        ]
    }
}

private struct FileWorkspaceToolProvider: ToolSource {
    let folder: FolderToolContext

    var toolOrigin: ToolOrigin {
        .workspace(id: folder.workspaceID, name: folder.rootURL.lastPathComponent)
    }

    func tools() async -> [AnyTool] {
        let workspace = FileSystemWorkspace(id: folder.workspaceID, rootURL: folder.rootURL)
        return Self.definitions.map {
            AnyTool(WorkspaceToolWrapper(workspace: workspace, definition: $0))
        }
    }

    private static let definitions: [WorkspaceToolDefinition] = [
        definition(
            id: "cat",
            name: "Read File",
            description: "Read a UTF-8 text file within the attached workspace.",
            properties: ["path": stringProperty],
            required: ["path"]
        ),
        definition(
            id: "ls",
            name: "List Directory",
            description: "List non-hidden files and directories within the attached workspace.",
            properties: ["path": stringProperty]
        ),
        definition(
            id: "find",
            name: "Find Files",
            description: "Find files and directories by name within the attached workspace.",
            properties: [
                "pattern": stringProperty,
                "path": stringProperty,
            ],
            required: ["pattern"]
        ),
        definition(
            id: "search_files",
            name: "Search Files",
            description: "Search file contents with a regular expression within the attached workspace.",
            properties: [
                "pattern": stringProperty,
                "path": stringProperty,
            ],
            required: ["pattern"]
        ),
        definition(
            id: "grep",
            name: "Search File Content",
            description: "Search file contents case-insensitively within the attached workspace.",
            properties: [
                "pattern": stringProperty,
                "path": stringProperty,
                "recursive": booleanProperty,
            ],
            required: ["pattern"]
        ),
        definition(
            id: "change_directory",
            name: "Change Directory",
            description: "Validate a directory path within the attached workspace.",
            properties: ["path": stringProperty],
            required: ["path"]
        ),
    ]

    private static let stringProperty: AnyCodable = .dictionary(["type": .string("string")])
    private static let booleanProperty: AnyCodable = .dictionary(["type": .string("boolean")])

    private static func definition(
        id: String,
        name: String,
        description: String,
        properties: [String: AnyCodable],
        required: [String] = []
    ) -> WorkspaceToolDefinition {
        var schema: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "additionalProperties": .boolean(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(AnyCodable.string))
        }
        return WorkspaceToolDefinition(
            id: id,
            name: name,
            description: description,
            parametersSchema: schema
        )
    }
}

private struct TerminalWorkspaceToolProvider: ToolSource {
    let terminal: TerminalToolContext
    let registry: TerminalSessionRegistry
    let approver: any TerminalCommandApproving

    var toolOrigin: ToolOrigin {
        .terminal(id: terminal.workspaceId, name: terminal.rootURL.lastPathComponent)
    }

    func tools() async -> [AnyTool] {
        [
            AnyTool(TerminalRunTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL, approver: approver)),
            AnyTool(TerminalReadTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL)),
            AnyTool(TerminalSendInputTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL)),
            AnyTool(TerminalInterruptTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL)),
            AnyTool(TerminalWaitTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL)),
            AnyTool(TerminalReadOutputTool(workspaceId: terminal.workspaceId, registry: registry, rootURL: terminal.rootURL)),
        ]
    }
}
