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
}
