import Foundation
import Observation

/// Main-actor view model backing the Monad profile settings surface (YAK-MON-9).
///
/// Owns exactly two things: reading/editing the active `MonadProfile` through
/// `AppSettingsStore`/`SecretStoring`, and driving a read-only `MonadConnectionStatus` check
/// against it. This is deliberately a separate type from `ProviderStatusViewModel` — that
/// view model owns Yakamoz's *local* provider settings (OpenAI/OpenRouter/Ollama/custom LLM
/// endpoint config), a different concept from a Monad server connection profile. Per
/// YAK-MON-9's "do not reuse Yakamoz local provider settings for Monad mode," the two never
/// share state.
///
/// This view model edits the *profile's own* connection fields (display name, server URL,
/// API key) — explicitly in scope per the ticket ("Users can configure the active Monad
/// profile"). It never writes the Monad *server's* own LLM provider configuration; the
/// `providerNotConfigured` status is read-only observation of that server-side state.
@MainActor
@Observable
public final class MonadProfileStatusViewModel {
    /// Backend factory seam: production wires `MonadYakamozBackend.init(profile:secrets:)`;
    /// tests inject a factory that returns a backend over a fully in-memory fake transport
    /// (see `MonadYakamozBackendTests.FakeTransport`), so no network call happens in `make test`.
    public typealias BackendFactory = @Sendable (MonadProfile, any SecretStoring) throws -> MonadYakamozBackend

    public private(set) var status: MonadConnectionStatus = .profileMissing
    public private(set) var isChecking = false
    public private(set) var lastCheckedAt: Date?

    private let settingsStore: AppSettingsStore
    private let secrets: any SecretStoring
    private let backendFactory: BackendFactory

    public init(
        settingsStore: AppSettingsStore = AppSettingsStore(),
        secrets: any SecretStoring,
        backendFactory: @escaping BackendFactory = { profile, secrets in
            try MonadYakamozBackend(profile: profile, secrets: secrets)
        }
    ) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.backendFactory = backendFactory
    }

    /// The active Monad profile, or `nil` when none has been saved yet.
    public var activeProfile: MonadProfile? {
        settingsStore.lastMonadProfile
    }

    /// Reads the active profile's stored API key (empty string when none is set), matching
    /// `ProviderStatusViewModel.loadAPIKey()`'s shape for the settings view to stage into a
    /// draft `@State` field.
    public func loadAPIKey() -> String {
        guard let profile = activeProfile else { return "" }
        return (try? profile.apiKey(secrets: secrets)) ?? ""
    }

    /// Creates (if none exists) or updates the active profile's display name and server URL.
    /// Persists through `AppSettingsStore`; never touches the server. Throws
    /// `MonadProfileConfigurationError.invalidServerURL` for an empty/schemeless/hostless URL
    /// string rather than silently saving something `verifyReachable()` could never reach.
    public func saveProfile(displayName: String, serverURLString: String) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURLString = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let url = URL(string: trimmedURLString),
            let scheme = url.scheme, !scheme.isEmpty,
            let host = url.host, !host.isEmpty
        else {
            throw MonadProfileConfigurationError.invalidServerURL
        }

        let resolvedName = trimmedName.isEmpty ? "Monad Server" : trimmedName
        var profile = activeProfile ?? MonadProfile(displayName: resolvedName, serverURL: url, isDefault: true)
        profile.displayName = resolvedName
        profile.serverURL = url
        settingsStore.lastMonadProfile = profile
        status = .profileMissing
        lastCheckedAt = nil
    }

    /// Validates, normalizes, and persists the drafted API key against the active profile.
    /// Throws `MonadProfileConfigurationError.noActiveProfile` if called before a profile has
    /// ever been saved.
    public func applyAPIKey(_ draft: String) throws {
        guard let profile = activeProfile else {
            throw MonadProfileConfigurationError.noActiveProfile
        }
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        try profile.setAPIKey(normalized.isEmpty ? nil : normalized, secrets: secrets)
    }

    /// Refreshes `status` by classifying the active profile's current reachability.
    ///
    /// Checks profile completeness locally first — no network call happens for
    /// `.profileMissing`. Otherwise constructs a backend for the profile and classifies its
    /// `/status` response (or the error constructing/calling it) into a `MonadConnectionStatus`.
    public func checkStatus() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let profile = activeProfile, Self.hasValidServerURL(profile) else {
            status = .profileMissing
            lastCheckedAt = .now
            return
        }

        do {
            let backend = try backendFactory(profile, secrets)
            status = await backend.fetchConnectionStatus()
        } catch {
            status = .unexpectedResponse(message: "\(error)")
        }
        lastCheckedAt = .now
    }

    private static func hasValidServerURL(_ profile: MonadProfile) -> Bool {
        guard let scheme = profile.serverURL.scheme, !scheme.isEmpty else { return false }
        guard let host = profile.serverURL.host, !host.isEmpty else { return false }
        return true
    }
}

/// Local validation errors for editing a `MonadProfile` through `MonadProfileStatusViewModel`.
/// These never reach the network — they guard against saving a profile `checkStatus()` could
/// never meaningfully classify.
public enum MonadProfileConfigurationError: Error, Sendable, Equatable, LocalizedError {
    case invalidServerURL
    case noActiveProfile

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid server URL, including scheme and host (e.g. http://127.0.0.1:8080)."
        case .noActiveProfile:
            "Save a Monad server profile before setting an API key."
        }
    }
}
