import Foundation
import Observation
import PKShared

/// Main-actor boundary for provider health and model-list state.
///
/// Shared by `SettingsView` and `ProviderControlMenu` so both surfaces reflect the same
/// connection and model-list state without each maintaining independent copies.
/// Lifecycle: create one instance per app lifetime in the composition root; inject into
/// both surfaces via environment or direct reference.
@MainActor
@Observable
public final class ProviderStatusViewModel {
    public var availableModels: [String] = []
    public var isLoadingModels = false
    public var modelLoadError: String?
    public var healthStatus: AppHealthStatus?
    public var isCheckingHealth = false
    public var lastHealthCheckAt: Date?

    private let settings: ProviderSettings
    private let secrets: any SecretStoring
    private let runtime: YakamozRuntime

    public init(settings: ProviderSettings, secrets: any SecretStoring, runtime: YakamozRuntime) {
        self.settings = settings
        self.secrets = secrets
        self.runtime = runtime
    }

    public var rankedModels: [String] {
        settings.rankedModels(from: availableModels)
    }

    public func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await runtime.fetchAvailableModels()
            modelLoadError = nil
        } catch {
            availableModels = []
            modelLoadError = "Model list unavailable. Manual entry remains available."
        }
    }

    public func testConnection() async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        healthStatus = await runtime.appHealthCheck()
        lastHealthCheckAt = .now
    }

    public func selectModel(_ modelID: String) {
        settings.applyModelSelection(modelID)
    }

    public func toggleFavoriteCurrent() {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        settings.toggleFavoriteModel(model)
    }

    /// Clears health and model-list state after the active target (preset/base URL/API key) changes
    /// so stale results from the previous endpoint are not mistaken for the new endpoint's status.
    public func clearStaleState() {
        healthStatus = nil
        lastHealthCheckAt = nil
        availableModels = []
        modelLoadError = nil
    }

    public func loadAPIKey() -> String {
        (try? ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)) ?? ""
    }

    /// Validates, normalizes, and persists the drafted API key. Throws `ProviderSettingsError`
    /// on validation failure; clears stale diagnostics and queues a model refresh on success.
    public func applyAPIKey(_ draft: String) throws {
        let normalized = ProviderSettings.normalizeAPIKey(draft)
        try settings.validateBaseURL()
        try settings.validateAPIKey(normalized)
        let account = ProviderSettings.apiKeyAccount(for: settings.preset)
        if normalized.isEmpty {
            try secrets.delete(account: account)
        } else {
            try secrets.write(normalized, account: account)
        }
        clearStaleState()
        Task { await refreshModels() }
    }
}
