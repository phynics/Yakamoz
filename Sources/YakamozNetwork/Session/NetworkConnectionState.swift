import Foundation

/// The connection lifecycle state of a ``NetworkClientSession``.
///
/// ```text
/// disabled --> connecting --> online --> (connection lost) --> retrying --> connecting
///                    \--> retrying --> ... --> failed (retry limit reached)
/// ```
public enum NetworkConnectionState: Sendable, Equatable {
    /// The client is switched off in settings.
    case disabled
    /// A connection attempt is in flight.
    case connecting
    /// The transport is connected and discovery has been seeded.
    case online
    /// A connection attempt failed; another is scheduled after a backoff delay.
    case retrying(attempt: Int, nextAttemptAt: Date?)
    /// The retry limit was reached; the client stopped trying.
    case failed(String)

    /// Whether the client is currently connected.
    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// Whether the client is actively trying to be connected.
    public var isActive: Bool {
        switch self {
        case .connecting, .online, .retrying: true
        case .disabled, .failed: false
        }
    }

    /// The failure detail when the retry limit was reached, otherwise `nil`.
    public var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }

    /// A short, user-facing label for the settings/status surface.
    public var label: String {
        switch self {
        case .disabled:
            "Off"
        case .connecting:
            "Connecting…"
        case .online:
            "Connected"
        case let .retrying(attempt, _):
            "Retrying (attempt \(attempt))…"
        case let .failed(message):
            "Failed: \(message)"
        }
    }
}
