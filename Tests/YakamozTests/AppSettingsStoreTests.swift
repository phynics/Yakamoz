import Foundation
import Testing
@testable import YakamozCore

@Suite("OperationMode")
struct OperationModeTests {
    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in OperationMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(OperationMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("Raw values are stable for persistence")
    func rawValues() {
        #expect(OperationMode.local.rawValue == "local")
        #expect(OperationMode.monad.rawValue == "monad")
    }
}

@Suite("MonadProfile")
struct MonadProfileTests {
    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let profile = try MonadProfile(
            displayName: "Home Server",
            serverURL: #require(URL(string: "https://monad.example.com")),
            isDefault: true
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(MonadProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test("API key is stored and read through SecretStoring, not plain UserDefaults")
    func apiKeyGoesThroughSecretStore() throws {
        let profile = try MonadProfile(displayName: "Home Server", serverURL: #require(URL(string: "https://monad.example.com")))
        let secrets = FakeSecretStore()

        #expect(try profile.apiKey(secrets: secrets) == nil)

        try profile.setAPIKey("super-secret-key", secrets: secrets)
        #expect(try profile.apiKey(secrets: secrets) == "super-secret-key")

        try profile.setAPIKey(nil, secrets: secrets)
        #expect(try profile.apiKey(secrets: secrets) == nil)
    }

    @Test("Blank API key is treated as absent")
    func blankAPIKeyIsAbsent() throws {
        let profile = try MonadProfile(displayName: "Home Server", serverURL: #require(URL(string: "https://monad.example.com")))
        let secrets = FakeSecretStore()

        try profile.setAPIKey("   ", secrets: secrets)
        #expect(try profile.apiKey(secrets: secrets) == nil)
    }

    @Test("Distinct profiles use distinct secret-store accounts")
    func distinctProfilesDoNotCollide() throws {
        let profileA = try MonadProfile(displayName: "A", serverURL: #require(URL(string: "https://a.example.com")))
        let profileB = try MonadProfile(displayName: "B", serverURL: #require(URL(string: "https://b.example.com")))
        let secrets = FakeSecretStore()

        try profileA.setAPIKey("key-a", secrets: secrets)
        try profileB.setAPIKey("key-b", secrets: secrets)

        #expect(try profileA.apiKey(secrets: secrets) == "key-a")
        #expect(try profileB.apiKey(secrets: secrets) == "key-b")
    }
}

@Suite("AppSettingsStore")
struct AppSettingsStoreTests {
    private func makeStore() -> AppSettingsStore {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettingsStore(defaults: defaults)
    }

    @Test("Defaults to .local mode on a fresh install")
    func defaultsToLocalMode() {
        let store = makeStore()
        #expect(store.lastOperationMode == .local)
    }

    @Test("Defaults to no stored Monad profile on a fresh install")
    func defaultsToNoProfile() {
        let store = makeStore()
        #expect(store.lastMonadProfile == nil)
    }

    @Test("Persists and retrieves the last operation mode")
    func persistsLastMode() {
        let store = makeStore()
        store.lastOperationMode = .monad
        #expect(store.lastOperationMode == .monad)

        store.lastOperationMode = .local
        #expect(store.lastOperationMode == .local)
    }

    @Test("Persists and retrieves the last Monad profile")
    func persistsLastProfile() throws {
        let store = makeStore()
        let profile = try MonadProfile(
            displayName: "Home Server",
            serverURL: #require(URL(string: "https://monad.example.com")),
            isDefault: true
        )

        store.lastMonadProfile = profile
        #expect(store.lastMonadProfile == profile)
    }

    @Test("Clearing the last profile removes it")
    func clearingProfileRemovesIt() throws {
        let store = makeStore()
        let profile = try MonadProfile(displayName: "Home Server", serverURL: #require(URL(string: "https://monad.example.com")))

        store.lastMonadProfile = profile
        #expect(store.lastMonadProfile != nil)

        store.lastMonadProfile = nil
        #expect(store.lastMonadProfile == nil)
    }

    @Test("A new instance backed by the same suite observes persisted values")
    func sharedSuitePersistsAcrossInstances() throws {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let first = AppSettingsStore(defaults: defaults)
        first.lastOperationMode = .monad
        first.lastMonadProfile = try MonadProfile(
            displayName: "Home Server",
            serverURL: #require(URL(string: "https://monad.example.com"))
        )

        let second = AppSettingsStore(defaults: defaults)
        #expect(second.lastOperationMode == .monad)
        #expect(second.lastMonadProfile?.displayName == "Home Server")
    }
}
