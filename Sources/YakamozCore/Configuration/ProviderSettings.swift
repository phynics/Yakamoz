import Foundation
import Observation
import PKShared
import PositronicKit

/// Identifies a well-known LLM provider endpoint, or a user-supplied custom one.
///
/// Distinct from PositronicKit's `LLMProvider` (which models the wire protocol a client
/// speaks — OpenAI-compatible, Ollama, etc.). `ProviderPreset` is a Yakamoz-only UI/settings
/// concept for picking a starting base URL; it maps onto `LLMProvider` in
/// `ProviderSettings.configuration(apiKey:)`.
public enum ProviderPreset: String, CaseIterable, Codable, Sendable {
    case openAI
    case openRouter
    case ollama
    case custom

    public var baseURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .ollama: URL(string: "http://localhost:11434/v1")!
        case .custom: URL(string: "http://localhost:8080/v1")!
        }
    }

    /// The PositronicKit wire-protocol provider this preset's client should speak.
    var llmProvider: LLMProvider {
        switch self {
        case .openAI: .openAI
        case .openRouter: .openRouter
        case .ollama: .ollama
        case .custom: .openAICompatible
        }
    }

    /// Whether this preset requires a non-blank API key (Ollama runs locally with no key).
    public var requiresAPIKey: Bool {
        self != .ollama
    }
}

/// A Sendable snapshot of the observable provider settings.
///
/// `ProviderSettings` itself is `@MainActor`-isolated. This value type lets actors and other
/// sendable consumers work with a stable copy of the current configuration without crossing
/// the main-actor boundary for every field access.
public struct ProviderSettingsSnapshot: Sendable, Equatable {
    public var preset: ProviderPreset
    public var baseURL: URL
    public var model: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var seed: Int?
    public var timeoutInterval: TimeInterval
    public var maxRetries: Int

    public init(
        preset: ProviderPreset,
        baseURL: URL,
        model: String,
        temperature: Double?,
        maxTokens: Int?,
        topP: Double?,
        frequencyPenalty: Double?,
        presencePenalty: Double?,
        seed: Int?,
        timeoutInterval: TimeInterval,
        maxRetries: Int
    ) {
        self.preset = preset
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
    }

    /// Maps this snapshot onto the real PositronicKit configuration type.
    public func configuration(apiKey: String) -> LLMConfiguration {
        LLMConfiguration(
            endpoint: baseURL.absoluteString,
            modelName: model,
            utilityModel: model,
            fastModel: model,
            apiKey: apiKey,
            provider: preset.llmProvider,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed
        )
    }

    /// Maps the generation knobs onto PositronicKit's `GenerationParameters`.
    public var generationParameters: GenerationParameters {
        GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed
        )
    }

    /// Retry knobs mapped for callers that want to drive `RetryPolicy.retry` directly.
    public var retrySettings: RetrySettings {
        RetrySettings(maxRetries: maxRetries, baseDelay: 1.0)
    }
}

/// Observable provider configuration for Yakamoz's settings UI.
///
/// Non-secret fields (preset, base URL, model, generation/retry knobs) persist to the
/// injected `UserDefaults`. API keys are never written to *this* `UserDefaults` instance —
/// they live only in the injected `SecretStoring` (a separately-suited `UserDefaultsSecretStore`
/// in production as of YAK-14, previously the Keychain), addressed by provider-specific
/// accounts from `Self.apiKeyAccount(for:)`.
@MainActor
@Observable
public final class ProviderSettings {
    /// Legacy OpenAI secret-store account. Keep this stable so existing OpenAI installs keep working.
    public nonisolated(unsafe) static let apiKeyAccount = "provider-api-key"

    /// Secret-store account for a provider preset's API key.
    public nonisolated static func apiKeyAccount(for preset: ProviderPreset) -> String {
        switch preset {
        case .openAI:
            return apiKeyAccount
        case .openRouter:
            return "\(apiKeyAccount).openRouter"
        case .ollama:
            return "\(apiKeyAccount).ollama"
        case .custom:
            return "\(apiKeyAccount).custom"
        }
    }

    /// Reads and normalizes the key for `preset`, with a constrained migration path for keys
    /// saved before provider-specific accounts existed.
    public nonisolated static func storedAPIKey(for preset: ProviderPreset, secrets: any SecretStoring) throws -> String {
        let primaryAccount = apiKeyAccount(for: preset)
        if let key = try secrets.read(account: primaryAccount).map(normalizeAPIKey), !key.isEmpty {
            return key
        }

        guard primaryAccount != apiKeyAccount,
              let legacyKey = try secrets.read(account: apiKeyAccount).map(normalizeAPIKey),
              legacyAPIKey(legacyKey, isCompatibleWith: preset)
        else {
            return ""
        }

        return legacyKey
    }

    public nonisolated static func normalizeAPIKey(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func legacyAPIKey(_ key: String, isCompatibleWith preset: ProviderPreset) -> Bool {
        switch preset {
        case .openAI:
            return true
        case .openRouter:
            return key.hasPrefix("sk-or-")
        case .ollama, .custom:
            return false
        }
    }

    private enum DefaultsKey {
        static let preset = "providerSettings.preset"
        static let baseURL = "providerSettings.baseURL"
        static let model = "providerSettings.model"
        static let temperature = "providerSettings.temperature"
        static let maxTokens = "providerSettings.maxTokens"
        static let topP = "providerSettings.topP"
        static let frequencyPenalty = "providerSettings.frequencyPenalty"
        static let presencePenalty = "providerSettings.presencePenalty"
        static let seed = "providerSettings.seed"
        static let timeoutInterval = "providerSettings.timeoutInterval"
        static let maxRetries = "providerSettings.maxRetries"
    }

    public var preset: ProviderPreset
    public var baseURL: URL
    public var model: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var seed: Int?
    public var timeoutInterval: TimeInterval
    public var maxRetries: Int

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedPresetRaw = defaults.string(forKey: DefaultsKey.preset)
        let resolvedPreset = storedPresetRaw.flatMap(ProviderPreset.init(rawValue:)) ?? .openAI
        preset = resolvedPreset

        if let storedURLString = defaults.string(forKey: DefaultsKey.baseURL),
           let storedURL = URL(string: storedURLString)
        {
            baseURL = storedURL
        } else {
            baseURL = resolvedPreset.baseURL
        }

        model = defaults.string(forKey: DefaultsKey.model) ?? "gpt-4o"
        temperature = defaults.object(forKey: DefaultsKey.temperature) as? Double
        maxTokens = defaults.object(forKey: DefaultsKey.maxTokens) as? Int
        topP = defaults.object(forKey: DefaultsKey.topP) as? Double
        frequencyPenalty = defaults.object(forKey: DefaultsKey.frequencyPenalty) as? Double
        presencePenalty = defaults.object(forKey: DefaultsKey.presencePenalty) as? Double
        seed = defaults.object(forKey: DefaultsKey.seed) as? Int

        let storedTimeout = defaults.object(forKey: DefaultsKey.timeoutInterval) as? Double
        timeoutInterval = storedTimeout ?? 60.0

        let storedRetries = defaults.object(forKey: DefaultsKey.maxRetries) as? Int
        maxRetries = storedRetries ?? 3
    }

    /// Applies a preset's default base URL. Does not touch the model or generation parameters.
    public func applyPreset(_ preset: ProviderPreset) {
        self.preset = preset
        baseURL = preset.baseURL
    }

    /// Validates the currently configured base URL. Only `http`/`https` schemes are accepted.
    public func validateBaseURL() throws {
        guard let scheme = baseURL.scheme, scheme == "http" || scheme == "https" else {
            throw ProviderSettingsError.invalidBaseURL(baseURL.absoluteString)
        }
        guard baseURL.host != nil else {
            throw ProviderSettingsError.invalidBaseURL(baseURL.absoluteString)
        }
    }

    /// Validates an API key against this preset's requirement. Ollama accepts a blank key.
    public func validateAPIKey(_ apiKey: String) throws {
        if preset.requiresAPIKey, apiKey.isEmpty {
            throw ProviderSettingsError.missingAPIKey
        }
    }

    /// Persists all non-secret fields to the injected `UserDefaults`. Never writes the API key.
    public func persist() {
        defaults.set(preset.rawValue, forKey: DefaultsKey.preset)
        defaults.set(baseURL.absoluteString, forKey: DefaultsKey.baseURL)
        defaults.set(model, forKey: DefaultsKey.model)
        setOrRemove(temperature, forKey: DefaultsKey.temperature)
        setOrRemove(maxTokens, forKey: DefaultsKey.maxTokens)
        setOrRemove(topP, forKey: DefaultsKey.topP)
        setOrRemove(frequencyPenalty, forKey: DefaultsKey.frequencyPenalty)
        setOrRemove(presencePenalty, forKey: DefaultsKey.presencePenalty)
        setOrRemove(seed, forKey: DefaultsKey.seed)
        defaults.set(timeoutInterval, forKey: DefaultsKey.timeoutInterval)
        defaults.set(maxRetries, forKey: DefaultsKey.maxRetries)
    }

    /// A Sendable snapshot of the current observable settings, suitable for actors.
    public var snapshot: ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            preset: preset,
            baseURL: baseURL,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            seed: seed,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries
        )
    }

    /// Reloads all non-secret fields from the injected `UserDefaults`, discarding in-memory edits.
    public func reload() {
        let storedPresetRaw = defaults.string(forKey: DefaultsKey.preset)
        preset = storedPresetRaw.flatMap(ProviderPreset.init(rawValue:)) ?? .openAI

        if let storedURLString = defaults.string(forKey: DefaultsKey.baseURL),
           let storedURL = URL(string: storedURLString)
        {
            baseURL = storedURL
        } else {
            baseURL = preset.baseURL
        }

        model = defaults.string(forKey: DefaultsKey.model) ?? "gpt-4o"
        temperature = defaults.object(forKey: DefaultsKey.temperature) as? Double
        maxTokens = defaults.object(forKey: DefaultsKey.maxTokens) as? Int
        topP = defaults.object(forKey: DefaultsKey.topP) as? Double
        frequencyPenalty = defaults.object(forKey: DefaultsKey.frequencyPenalty) as? Double
        presencePenalty = defaults.object(forKey: DefaultsKey.presencePenalty) as? Double
        seed = defaults.object(forKey: DefaultsKey.seed) as? Int
        timeoutInterval = (defaults.object(forKey: DefaultsKey.timeoutInterval) as? Double) ?? 60.0
        maxRetries = (defaults.object(forKey: DefaultsKey.maxRetries) as? Int) ?? 3
    }

    private func setOrRemove(_ value: Double?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func setOrRemove(_ value: Int?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Maps the current settings plus a freshly read secret into the real PositronicKit
    /// `LLMConfiguration`, using its flat legacy initializer (endpoint/apiKey/modelName/...).
    public func configuration(apiKey: String) -> LLMConfiguration {
        snapshot.configuration(apiKey: apiKey)
    }

    /// Maps the current generation knobs onto PositronicKit's `GenerationParameters`.
    public var generationParameters: GenerationParameters {
        snapshot.generationParameters
    }

    /// Retry knobs mapped for callers that want to drive `RetryPolicy.retry` directly.
    /// `RetryPolicy` itself exposes only static helpers (no stored configuration type to
    /// construct), so this value type bundles the two knobs `ProviderSettings` owns.
    public var retrySettings: RetrySettings {
        snapshot.retrySettings
    }
}

/// The two knobs `ProviderSettings` tracks for retry behavior, for callers that invoke
/// `RetryPolicy.retry(maxRetries:baseDelay:...)` directly. `RetryPolicy` in PositronicKit is a
/// namespace of static helpers with no stored configuration struct to construct against.
public struct RetrySettings: Sendable, Equatable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval

    public init(maxRetries: Int, baseDelay: TimeInterval) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }
}

public enum ProviderSettingsError: Error, Equatable, LocalizedError {
    case invalidBaseURL(String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            return "Invalid provider base URL: \(value)"
        case .missingAPIKey:
            return "An API key is required for this provider."
        }
    }
}
