import Foundation

/// Persists the app-wide "last used operation mode + Monad profile" default, queried at new
/// window-creation time.
///
/// This is intentionally the *only* thing this ticket (YAK-MON-1) persists: no Monad
/// conversation/timeline/workspace/agent data is cached locally, and no UI wiring happens here
/// — later YAK-MON tickets read `AppSettingsStore` to decide what a new window starts as.
///
/// Non-secret fields (mode, profile id/name/URL/default marker) persist to the injected
/// `UserDefaults`. A profile's API key never touches this `UserDefaults` instance — it flows
/// only through the injected `SecretStoring`, following the same split `ProviderSettings` uses.
public struct AppSettingsStore: @unchecked Sendable {
    private enum DefaultsKey {
        static let lastMode = "appSettings.lastOperationMode"
        static let lastProfileID = "appSettings.lastMonadProfile.id"
        static let lastProfileDisplayName = "appSettings.lastMonadProfile.displayName"
        static let lastProfileServerURL = "appSettings.lastMonadProfile.serverURL"
        static let lastProfileIsDefault = "appSettings.lastMonadProfile.isDefault"
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: Backing `UserDefaults`. Defaults to `.standard`, matching
    ///   `ProviderSettings`. Pass an isolated suite/instance in tests.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The operation mode a new window should start in. Defaults to `.local` on a fresh
    /// install (no stored value, or a corrupted/unrecognized stored value).
    public var lastOperationMode: OperationMode {
        get {
            defaults.string(forKey: DefaultsKey.lastMode)
                .flatMap(OperationMode.init(rawValue:)) ?? .local
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.lastMode)
        }
    }

    /// The Monad profile a new window should start from when in `.monad` mode. `nil` when no
    /// profile has ever been saved (e.g. fresh install, or local-only usage so far).
    public var lastMonadProfile: MonadProfile? {
        get {
            guard
                let idString = defaults.string(forKey: DefaultsKey.lastProfileID),
                let id = UUID(uuidString: idString),
                let displayName = defaults.string(forKey: DefaultsKey.lastProfileDisplayName),
                let urlString = defaults.string(forKey: DefaultsKey.lastProfileServerURL),
                let serverURL = URL(string: urlString)
            else {
                return nil
            }
            let isDefault = defaults.bool(forKey: DefaultsKey.lastProfileIsDefault)
            return MonadProfile(id: id, displayName: displayName, serverURL: serverURL, isDefault: isDefault)
        }
        nonmutating set {
            guard let profile = newValue else {
                defaults.removeObject(forKey: DefaultsKey.lastProfileID)
                defaults.removeObject(forKey: DefaultsKey.lastProfileDisplayName)
                defaults.removeObject(forKey: DefaultsKey.lastProfileServerURL)
                defaults.removeObject(forKey: DefaultsKey.lastProfileIsDefault)
                return
            }
            defaults.set(profile.id.uuidString, forKey: DefaultsKey.lastProfileID)
            defaults.set(profile.displayName, forKey: DefaultsKey.lastProfileDisplayName)
            defaults.set(profile.serverURL.absoluteString, forKey: DefaultsKey.lastProfileServerURL)
            defaults.set(profile.isDefault, forKey: DefaultsKey.lastProfileIsDefault)
        }
    }
}
