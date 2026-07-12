import Foundation

/// A Monad server connection profile: an app-settings value, not SwiftData domain data.
///
/// v1 keeps exactly one active profile persisted (via `AppSettingsStore`), but the model is
/// deliberately profile-list-ready (stable `id`, `isDefault` marker) so a later ticket can add
/// a profile list without reshaping this type.
///
/// The API key is intentionally **not** a stored property here — like `ProviderSettings`, it
/// flows only through `SecretStoring`, addressed by `MonadProfile.apiKeyAccount(for:)`, and is
/// never serialized alongside the rest of the profile.
public struct MonadProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var serverURL: URL
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        serverURL: URL,
        isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.isDefault = isDefault
    }

    /// Secret-store account for this profile's optional API key, namespaced by profile id so
    /// distinct profiles never collide even if their display names or URLs match.
    public static func apiKeyAccount(for profileID: UUID) -> String {
        "monadProfile.apiKey.\(profileID.uuidString)"
    }

    /// Reads this profile's API key through `secrets`, normalizing like `ProviderSettings` does.
    /// Returns `nil` when no key has been stored (the key is optional for a Monad profile).
    public func apiKey(secrets: any SecretStoring) throws -> String? {
        guard let stored = try secrets.read(account: Self.apiKeyAccount(for: id)) else {
            return nil
        }
        let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Writes (or clears, when `apiKey` is `nil`/blank) this profile's API key through `secrets`.
    public func setAPIKey(_ apiKey: String?, secrets: any SecretStoring) throws {
        let account = Self.apiKeyAccount(for: id)
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            try secrets.write(normalized, account: account)
        } else {
            try secrets.delete(account: account)
        }
    }
}
