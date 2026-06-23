import Foundation
import PKOpenAIProvider
import PKShared
import PositronicKit
import SwiftData

/// Builds the `any LLMServiceProtocol` that `YakamozRuntime` hands to `PositronicKit`.
///
/// Defaults to the real `PKOpenAIProvider`-registered `LLMService`. Tests substitute a factory
/// that returns a mock (e.g. `PKTestSupport.MockLLMService`) so no network call ever happens
/// during `make test`.
public typealias LLMServiceFactory = @Sendable (LLMConfiguration) -> any LLMServiceProtocol

/// The default factory used in production: registers `PKOpenAIProvider`'s client factories and
/// constructs a real `LLMService` from the given configuration.
public func defaultLLMServiceFactory(configuration: LLMConfiguration) -> any LLMServiceProtocol {
    PKOpenAIProvider.register()
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
public actor YakamozRuntime {
    public let kit: PositronicKit
    public let stores: YakamozStores
    public let inspector: SwiftDataTurnInspector
    private let llmService: any LLMServiceProtocol

    @MainActor
    public init(
        modelContainer: ModelContainer,
        settings: ProviderSettings,
        secrets: any SecretStoring,
        llmServiceFactory: LLMServiceFactory = defaultLLMServiceFactory
    ) throws {
        stores = YakamozStores(modelContainer: modelContainer)
        inspector = SwiftDataTurnInspector(modelContainer: modelContainer)

        let key = try secrets.read(account: ProviderSettings.apiKeyAccount) ?? ""
        let configuration = settings.configuration(apiKey: key)
        llmService = llmServiceFactory(configuration)

        kit = PositronicKit(
            llmService: llmService,
            messageStore: stores.messages,
            agentInstanceStore: stores.agents,
            requestOriginStore: stores.origins,
            timelinePersistence: stores.timelines,
            workspacePersistence: stores.workspaces,
            toolPersistence: stores.tools,
            turnInspector: inspector,
            generationParameters: settings.generationParameters
        )
    }

    /// Delegates to the underlying LLM service's health check exactly once per call.
    public func healthCheck() async -> HealthStatus {
        await llmService.checkHealth()
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
        systemInstructions: String? = nil
    ) async -> ChatViewModel {
        let runner = kit
        let turnInspector = inspector
        return ChatViewModel(
            timelineId: timelineId,
            runner: runner,
            inspector: turnInspector,
            agentInstanceId: agentInstanceId,
            systemInstructions: systemInstructions
        )
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
}
