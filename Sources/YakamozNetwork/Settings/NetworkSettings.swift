import Foundation
import Observation
import YakamozCore

/// Default broker endpoint values shown on a fresh install.
public enum NetworkSettingsDefaults {
    /// Loopback broker host.
    public static let host = "127.0.0.1"
    /// Standard MQTT broker port.
    public static let port = 1883
    /// Axoloty namespace shared with the serving Node.
    public static let namespace = "gnostic"
    /// Axoloty client identity Yakamoz publishes.
    public static let identity = "yakamoz"
}

/// A `Sendable` snapshot of the non-secret network settings.
///
/// `NetworkSettings` is `@MainActor`-isolated; this value type lets sendable
/// consumers read a stable copy without crossing the main-actor boundary per
/// field. The broker password is deliberately absent: it lives only in the
/// secret store and is folded in by ``NetworkSettings/brokerConfiguration(secrets:)``.
public struct NetworkSettingsSnapshot: Sendable, Equatable {
    /// The MQTT broker host.
    public var host: String
    /// The MQTT broker port.
    public var port: Int
    /// The Axoloty namespace shared with the serving Node.
    public var namespace: String
    /// The Axoloty identity Yakamoz publishes.
    public var identity: String
    /// The broker username, or `nil`/empty for anonymous access.
    public var username: String
    /// Whether the client should connect on launch.
    public var isEnabled: Bool

    public init(
        host: String,
        port: Int,
        namespace: String,
        identity: String,
        username: String,
        isEnabled: Bool
    ) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.identity = identity
        self.username = username
        self.isEnabled = isEnabled
    }
}

/// The wire-facing broker configuration a ``GnosticClientTransport`` connects with.
///
/// Non-empty credential strings are normalized to `nil`, matching
/// `GnosticBrokerSettings`' own contract (MQTT forbids a blank username).
public struct NetworkBrokerConfiguration: Sendable, Equatable {
    /// The MQTT broker host.
    public var host: String
    /// The MQTT broker port.
    public var port: Int
    /// The Axoloty namespace shared with the serving Node.
    public var namespace: String
    /// The Axoloty identity Yakamoz publishes.
    public var identity: String
    /// The broker username, or `nil` for anonymous access.
    public var username: String?
    /// The broker password, or `nil` for anonymous access.
    public var password: String?
    /// Whether the client should connect at all.
    public var isEnabled: Bool

    public init(
        host: String,
        port: Int,
        namespace: String,
        identity: String,
        username: String? = nil,
        password: String? = nil,
        isEnabled: Bool
    ) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.identity = identity
        self.username = Self.normalized(username)
        self.password = Self.normalized(password)
        self.isEnabled = isEnabled
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// A validation problem with the network settings.
public enum NetworkSettingsIssue: Error, Hashable, Sendable, LocalizedError {
    case emptyHost
    case invalidPort(Int)
    case emptyNamespace
    case emptyIdentity
    case passwordWithoutUsername

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            "Broker host cannot be empty."
        case let .invalidPort(port):
            "Broker port \(port) is out of range (1–65535)."
        case .emptyNamespace:
            "Network namespace cannot be empty."
        case .emptyIdentity:
            "Client identity cannot be empty."
        case .passwordWithoutUsername:
            "A broker password requires a username."
        }
    }
}

/// Observable Gnostic network configuration for the Network settings pane.
///
/// Mirrors ``ProviderSettings``: non-secret fields persist to the injected
/// `UserDefaults`, while the broker password travels only through the injected
/// ``SecretStoring`` under ``passwordAccount``. The same plaintext-`UserDefaults`
/// tradeoff documented for provider keys applies here (YAK-14).
@MainActor
@Observable
public final class NetworkSettings {
    /// Secret-store account used for the broker password.
    public nonisolated static let passwordAccount = "network.broker.password"

    private enum DefaultsKey {
        static let host = "networkSettings.host"
        static let port = "networkSettings.port"
        static let namespace = "networkSettings.namespace"
        static let identity = "networkSettings.identity"
        static let username = "networkSettings.username"
        static let isEnabled = "networkSettings.isEnabled"
    }

    /// The MQTT broker host.
    public var host: String
    /// The MQTT broker port.
    public var port: Int
    /// The Axoloty namespace shared with the serving Node.
    public var namespace: String
    /// The Axoloty identity Yakamoz publishes.
    public var identity: String
    /// The broker username.
    public var username: String
    /// Whether the client connects on launch.
    public var isEnabled: Bool

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: DefaultsKey.host) ?? NetworkSettingsDefaults.host
        port = defaults.object(forKey: DefaultsKey.port) as? Int ?? NetworkSettingsDefaults.port
        namespace = defaults.string(forKey: DefaultsKey.namespace) ?? NetworkSettingsDefaults.namespace
        identity = defaults.string(forKey: DefaultsKey.identity) ?? NetworkSettingsDefaults.identity
        username = defaults.string(forKey: DefaultsKey.username) ?? ""
        isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) as? Bool ?? false
    }

    /// A `Sendable` snapshot of the non-secret fields.
    public var snapshot: NetworkSettingsSnapshot {
        NetworkSettingsSnapshot(
            host: host,
            port: port,
            namespace: namespace,
            identity: identity,
            username: username,
            isEnabled: isEnabled
        )
    }

    /// Persists all non-secret fields. Never writes the broker password.
    public func persist() {
        defaults.set(host, forKey: DefaultsKey.host)
        defaults.set(port, forKey: DefaultsKey.port)
        defaults.set(namespace, forKey: DefaultsKey.namespace)
        defaults.set(identity, forKey: DefaultsKey.identity)
        defaults.set(username, forKey: DefaultsKey.username)
        defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
    }

    /// Reloads all non-secret fields from the injected `UserDefaults`.
    public func reload() {
        host = defaults.string(forKey: DefaultsKey.host) ?? NetworkSettingsDefaults.host
        port = defaults.object(forKey: DefaultsKey.port) as? Int ?? NetworkSettingsDefaults.port
        namespace = defaults.string(forKey: DefaultsKey.namespace) ?? NetworkSettingsDefaults.namespace
        identity = defaults.string(forKey: DefaultsKey.identity) ?? NetworkSettingsDefaults.identity
        username = defaults.string(forKey: DefaultsKey.username) ?? ""
        isEnabled = defaults.object(forKey: DefaultsKey.isEnabled) as? Bool ?? false
    }

    /// Returns every validation problem with the current settings, in field order.
    ///
    /// An empty result means the settings are safe to hand to a transport.
    public func validate() -> [NetworkSettingsIssue] {
        var issues: [NetworkSettingsIssue] = []
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyHost)
        }
        if !(1 ... 65535).contains(port) {
            issues.append(.invalidPort(port))
        }
        if namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyNamespace)
        }
        if identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyIdentity)
        }
        return issues
    }

    /// Returns every validation problem, including the secret-dependent
    /// password-without-username rule (MQTT forbids a password with no username).
    public func validate(password: String?) -> [NetworkSettingsIssue] {
        var issues = validate()
        let hasPassword = !(password ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPassword, !hasUsername {
            issues.append(.passwordWithoutUsername)
        }
        return issues
    }

    /// Reads the stored broker password, normalized to `nil` when blank.
    public func storedPassword(secrets: any SecretStoring) throws -> String? {
        let stored = try secrets.read(account: Self.passwordAccount) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes (or clears, when blank) the broker password in the secret store.
    public func applyPassword(_ password: String, secrets: any SecretStoring) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.delete(account: Self.passwordAccount)
        } else {
            try secrets.write(trimmed, account: Self.passwordAccount)
        }
    }

    /// Builds the wire-facing broker configuration, folding in the secret password.
    public func brokerConfiguration(secrets: any SecretStoring) throws -> NetworkBrokerConfiguration {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkBrokerConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            namespace: namespace.trimmingCharacters(in: .whitespacesAndNewlines),
            identity: identity.trimmingCharacters(in: .whitespacesAndNewlines),
            username: trimmedUsername.isEmpty ? nil : trimmedUsername,
            password: try storedPassword(secrets: secrets),
            isEnabled: isEnabled
        )
    }
}
