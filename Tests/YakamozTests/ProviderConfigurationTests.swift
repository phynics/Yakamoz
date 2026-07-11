import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// In-memory `SecretStoring` fake. Never touches the real Keychain, so these tests are safe to
/// run on CI without entitlements.
final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func read(account: String) throws -> String? {
        storage[account]
    }

    func write(_ value: String, account: String) throws {
        storage[account] = value
    }

    func delete(account: String) throws {
        storage.removeValue(forKey: account)
    }
}

@Suite("ProviderConfiguration")
@MainActor
struct ProviderConfigurationTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ProviderConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Preset URLs

    @Test("Preset base URLs match the documented endpoints")
    func presetBaseURLs() {
        #expect(ProviderPreset.openAI.baseURL.absoluteString == "https://api.openai.com/v1")
        #expect(ProviderPreset.openRouter.baseURL.absoluteString == "https://openrouter.ai/api/v1")
        #expect(ProviderPreset.ollama.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(ProviderPreset.custom.baseURL.absoluteString == "http://localhost:8080/v1")
    }

    // MARK: - Blank Ollama key acceptance

    @Test("Ollama preset accepts a blank API key")
    func ollamaAcceptsBlankKey() throws {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.applyPreset(.ollama)
        try settings.validateAPIKey("")
    }

    @Test("Non-Ollama presets reject a blank API key")
    func nonOllamaRejectsBlankKey() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.applyPreset(.openAI)
        #expect(throws: ProviderSettingsError.missingAPIKey) {
            try settings.validateAPIKey("")
        }
    }

    // MARK: - Custom URL validation

    @Test("A valid custom http/https URL passes validation")
    func validCustomURLPasses() throws {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.applyPreset(.custom)
        settings.baseURL = try #require(URL(string: "https://my-llm.example.com/v1"))
        try settings.validateBaseURL()
    }

    @Test("A non-http(s) scheme fails validation")
    func invalidSchemeFails() throws {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.baseURL = try #require(URL(string: "ftp://example.com"))
        #expect(throws: ProviderSettingsError.self) {
            try settings.validateBaseURL()
        }
    }

    @Test("A URL with no host fails validation")
    func missingHostFails() throws {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.baseURL = try #require(URL(string: "https:///path-only"))
        #expect(throws: ProviderSettingsError.self) {
            try settings.validateBaseURL()
        }
    }

    // MARK: - Persistence reload

    @Test("Persisted non-secret fields survive a reload from a fresh instance")
    func persistenceReload() throws {
        let defaults = makeDefaults()
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.custom)
        settings.baseURL = try #require(URL(string: "https://custom.example.com/v1"))
        settings.model = "my-model"
        settings.temperature = 0.5
        settings.maxTokens = 2048
        settings.timeoutInterval = 30
        settings.maxRetries = 5
        settings.persist()

        let reloaded = ProviderSettings(defaults: defaults)
        #expect(reloaded.preset == .custom)
        #expect(reloaded.baseURL.absoluteString == "https://custom.example.com/v1")
        #expect(reloaded.model == "my-model")
        #expect(reloaded.temperature == 0.5)
        #expect(reloaded.maxTokens == 2048)
        #expect(reloaded.timeoutInterval == 30)
        #expect(reloaded.maxRetries == 5)
    }

    @Test("reload() discards in-memory edits and re-reads from defaults")
    func reloadDiscardsInMemoryEdits() {
        let defaults = makeDefaults()
        let settings = ProviderSettings(defaults: defaults)
        settings.model = "persisted-model"
        settings.persist()

        settings.model = "unsaved-edit"
        settings.reload()

        #expect(settings.model == "persisted-model")
    }

    // MARK: - Generation / retry mapping

    @Test("generationParameters maps settings onto GenerationParameters")
    func generationParametersMapping() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.temperature = 0.7
        settings.maxTokens = 512
        settings.topP = 0.9
        settings.frequencyPenalty = 0.1
        settings.presencePenalty = 0.2
        settings.seed = 42

        let params = settings.generationParameters
        #expect(params.temperature == 0.7)
        #expect(params.maxTokens == 512)
        #expect(params.topP == 0.9)
        #expect(params.frequencyPenalty == 0.1)
        #expect(params.presencePenalty == 0.2)
        #expect(params.seed == 42)
    }

    @Test("retrySettings maps maxRetries and a base delay")
    func retrySettingsMapping() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.maxRetries = 7
        let retry = settings.retrySettings
        #expect(retry.maxRetries == 7)
        #expect(retry.baseDelay == 1.0)
    }

    @Test("configuration(apiKey:) maps to LLMConfiguration with the provided key")
    func configurationMapping() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o"

        let config = settings.configuration(apiKey: "sk-secret-test-key")
        #expect(config.activeProvider == .openAI)
        #expect(config.apiKey == "sk-secret-test-key")
        #expect(config.modelName == "gpt-4o")
        #expect(config.endpoint == ProviderPreset.openAI.baseURL.absoluteString)
    }

    @Test("API key accounts are scoped per provider")
    func apiKeyAccountsAreScopedPerProvider() {
        #expect(ProviderSettings.apiKeyAccount(for: .openAI) == ProviderSettings.apiKeyAccount)
        #expect(ProviderSettings.apiKeyAccount(for: .openRouter) == "provider-api-key.openRouter")
        #expect(ProviderSettings.apiKeyAccount(for: .custom) == "provider-api-key.custom")
        #expect(ProviderSettings.apiKeyAccount(for: .ollama) == "provider-api-key.ollama")
    }

    @Test("storedAPIKey reads the selected provider account")
    func storedAPIKeyReadsSelectedProviderAccount() throws {
        let secrets = FakeSecretStore()
        try secrets.write("sk-openai-secret", account: ProviderSettings.apiKeyAccount(for: .openAI))
        try secrets.write(" sk-or-v1-openrouter-secret\n", account: ProviderSettings.apiKeyAccount(for: .openRouter))

        #expect(try ProviderSettings.storedAPIKey(for: .openAI, secrets: secrets) == "sk-openai-secret")
        #expect(try ProviderSettings.storedAPIKey(for: .openRouter, secrets: secrets) == "sk-or-v1-openrouter-secret")
    }

    @Test("OpenRouter only migrates compatible legacy API keys")
    func openRouterLegacyMigrationRequiresOpenRouterKey() throws {
        let secrets = FakeSecretStore()
        try secrets.write("sk-openai-secret", account: ProviderSettings.apiKeyAccount)

        #expect(try ProviderSettings.storedAPIKey(for: .openRouter, secrets: secrets) == "")

        try secrets.write(" sk-or-v1-legacy-openrouter-secret\n", account: ProviderSettings.apiKeyAccount)
        #expect(try ProviderSettings.storedAPIKey(for: .openRouter, secrets: secrets) == "sk-or-v1-legacy-openrouter-secret")
    }

    @Test("favorites and recents are scoped by provider and base URL")
    func favoritesAndRecentsAreScopedByProviderAndBaseURL() throws {
        let defaults = makeDefaults()
        let settings = ProviderSettings(defaults: defaults)

        settings.applyPreset(.openAI)
        settings.baseURL = try #require(URL(string: "https://api.openai.com/v1"))
        settings.toggleFavoriteModel("gpt-4.1")
        settings.recordRecentModel("gpt-4o-mini")

        settings.applyPreset(.custom)
        settings.baseURL = try #require(URL(string: "https://example.invalid/v1"))
        #expect(settings.favoriteModels().isEmpty)
        #expect(settings.recentModels().isEmpty)

        settings.toggleFavoriteModel("custom-model")
        settings.recordRecentModel("custom-recent")

        settings.applyPreset(.openAI)
        settings.baseURL = try #require(URL(string: "https://api.openai.com/v1"))
        #expect(settings.favoriteModels() == ["gpt-4.1"])
        #expect(settings.recentModels() == ["gpt-4o-mini"])
    }

    @Test("ranked models keep favorites first, then recents, and retain the current model")
    func rankedModelsFavorFavoritesAndRecents() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.model = "manual-current"
        settings.toggleFavoriteModel("gpt-4.1")
        settings.recordRecentModel("gpt-4o-mini")

        let ranked = settings.rankedModels(from: ["gpt-4o-mini", "gpt-4.1", "gpt-4o"])

        #expect(ranked == ["gpt-4.1", "gpt-4o-mini", "manual-current", "gpt-4o"])
    }

    @Test("model catalog normalization preserves provider order and appends the current model when missing")
    func modelCatalogNormalizationAppendsMissingCurrentModel() {
        let normalized = ModelCatalogService().normalize(
            models: ["mock-model", " mock-model ", "", "gpt-4o-mini"],
            currentModel: "manual-current"
        )

        #expect(normalized == ["mock-model", "gpt-4o-mini", "manual-current"])
    }

    // MARK: - No API key in UserDefaults

    @Test("No API key ever appears in UserDefaults, even after persist()")
    func noAPIKeyInDefaults() throws {
        let defaults = makeDefaults()
        let settings = ProviderSettings(defaults: defaults)
        let secrets = FakeSecretStore()

        settings.applyPreset(.openAI)
        settings.model = "gpt-4o"
        settings.persist()
        try secrets.write("sk-secret-test-key", account: ProviderSettings.apiKeyAccount)

        #expect(defaults.dictionaryRepresentation().values.allSatisfy {
            !String(describing: $0).contains("sk-secret")
        })

        // The secret is retrievable only through SecretStoring.
        #expect(try secrets.read(account: ProviderSettings.apiKeyAccount) == "sk-secret-test-key")
    }

    // MARK: - SecretStoring fake round-trip

    @Test("FakeSecretStore round-trips write/read/delete")
    func fakeSecretStoreRoundTrip() throws {
        let secrets = FakeSecretStore()
        #expect(try secrets.read(account: "acct") == nil)

        try secrets.write("value-1", account: "acct")
        #expect(try secrets.read(account: "acct") == "value-1")

        try secrets.write("value-2", account: "acct")
        #expect(try secrets.read(account: "acct") == "value-2")

        try secrets.delete(account: "acct")
        #expect(try secrets.read(account: "acct") == nil)
    }
}
