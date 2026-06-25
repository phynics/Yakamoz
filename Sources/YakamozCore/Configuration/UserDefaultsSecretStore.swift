import Foundation

/// Abstraction over secret storage, so production code can use a concrete backing store while
/// tests use an in-memory fake (`FakeSecretStore`). API keys must only ever flow through this
/// protocol — call sites never read/write the backing store directly.
public protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// `SecretStoring` backed by a named `UserDefaults` suite, scoped by app identity.
///
/// ⚠️ **Plaintext storage.** This is an explicit, accepted downgrade from Keychain storage
/// (YAK-14): values land in `~/Library/Preferences/<suite-name>.plist`, readable by any
/// process running as the user and included in unencrypted backups. Acceptable for a local
/// showcase app; do not reuse this store for anything that needs real secrecy. See the
/// README's "Providers, presets, and secret storage" section for the full tradeoff writeup.
public struct UserDefaultsSecretStore: SecretStoring, @unchecked Sendable {
    /// Suite name keyed off the app's bundle identity (YAK-13), so the secret store and the
    /// SwiftData store directory move together when the bundle id changes.
    public static let defaultSuiteName = "me.atkn.Yakamoz.secrets"

    private let defaults: UserDefaults

    /// - Parameter suiteName: Name of the backing `UserDefaults` suite. Defaults to
    ///   `Self.defaultSuiteName`. Pass a unique suite name in tests instead of using
    ///   `FakeSecretStore` if a real-but-isolated suite is needed.
    public init(suiteName: String = UserDefaultsSecretStore.defaultSuiteName) {
        // UserDefaults(suiteName:) only returns nil for a malformed suite name; ours is a
        // fixed, valid literal, so falling back to .standard keeps behavior defined without
        // ever crashing production startup.
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Namespaces every key under a fixed prefix so this suite can't collide with any other
    /// `UserDefaults` consumer that happens to share the suite (defensive; the suite is
    /// dedicated to secrets today).
    private func key(for account: String) -> String {
        "secret.\(account)"
    }

    public func read(account: String) throws -> String? {
        defaults.string(forKey: key(for: account))
    }

    public func write(_ value: String, account: String) throws {
        defaults.set(value, forKey: key(for: account))
    }

    public func delete(account: String) throws {
        defaults.removeObject(forKey: key(for: account))
    }
}
