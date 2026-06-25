import Foundation
import Testing
@testable import YakamozCore

@Suite("UserDefaultsSecretStore")
struct UserDefaultsSecretStoreTests {
    private func makeStore() -> (UserDefaultsSecretStore, String) {
        let suiteName = "UserDefaultsSecretStoreTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        return (UserDefaultsSecretStore(suiteName: suiteName), suiteName)
    }

    @Test("Round-trips write/read/delete for a single account")
    func roundTrip() throws {
        let (store, _) = makeStore()
        #expect(try store.read(account: "acct") == nil)

        try store.write("value-1", account: "acct")
        #expect(try store.read(account: "acct") == "value-1")

        try store.write("value-2", account: "acct")
        #expect(try store.read(account: "acct") == "value-2")

        try store.delete(account: "acct")
        #expect(try store.read(account: "acct") == nil)
    }

    @Test("Per-provider accounts are kept separate")
    func accountSeparation() throws {
        let (store, _) = makeStore()

        try store.write("sk-openai", account: "provider-api-key")
        try store.write("sk-or-v1-openrouter", account: "provider-api-key.openRouter")
        try store.write("ollama-key", account: "provider-api-key.ollama")

        #expect(try store.read(account: "provider-api-key") == "sk-openai")
        #expect(try store.read(account: "provider-api-key.openRouter") == "sk-or-v1-openrouter")
        #expect(try store.read(account: "provider-api-key.ollama") == "ollama-key")

        try store.delete(account: "provider-api-key.openRouter")
        #expect(try store.read(account: "provider-api-key.openRouter") == nil)
        // Deleting one account never touches a sibling account.
        #expect(try store.read(account: "provider-api-key") == "sk-openai")
        #expect(try store.read(account: "provider-api-key.ollama") == "ollama-key")
    }

    @Test("Values written by one store instance are visible to another instance of the same suite")
    func sharedSuitePersistsAcrossInstances() throws {
        let suiteName = "UserDefaultsSecretStoreTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)

        let first = UserDefaultsSecretStore(suiteName: suiteName)
        try first.write("persisted-secret", account: "acct")

        let second = UserDefaultsSecretStore(suiteName: suiteName)
        #expect(try second.read(account: "acct") == "persisted-secret")
    }
}
