import Foundation

/// A change pushed by a ``GnosticClientTransport`` as it observes the network.
///
/// This is the module-local seam event. Upstream `GnosticCore` catalog types are
/// mapped into ``DiscoveredNetworkObject`` inside `GnosticCoreTransport`, so no
/// GnosticCore symbol crosses this boundary.
public enum GnosticTransportEvent: Sendable, Equatable {
    /// A supported object was advertised or resolved.
    case discovered(DiscoveredNetworkObject)
    /// A previously listed object was deadvertised by its provider.
    case deadvertised(NetworkObjectKey)
    /// A provider published a lifecycle identity deadvertisement; every record
    /// owned by that provider was removed.
    case providerEvicted(providerID: String)
    /// The transport lost its broker connection.
    case connectionLost(reason: String)
}

/// Failures a transport can raise while connecting or discovering.
public enum GnosticTransportError: Error, Sendable, Equatable, LocalizedError {
    /// A discover request was issued before a successful connect.
    case notConnected
    /// The transport could not reach or start the broker session.
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The Gnostic transport is not connected."
        case let .connectionFailed(detail):
            "Could not connect to the Gnostic broker: \(detail)"
        }
    }
}

/// The connection/discovery seam between ``NetworkClientSession`` and a concrete
/// Gnostic client.
///
/// Production is ``GnosticCoreTransport``; tests use an offline fake. Keeping the
/// seam narrow means the connection lifecycle, backoff, and catalog reduction stay
/// pure and unit-testable with no broker in CI (issue #8).
public protocol GnosticClientTransport: Sendable {
    /// Establishes a broker session using `configuration`.
    ///
    /// - Throws: ``GnosticTransportError`` when the session cannot start.
    func connect(_ configuration: NetworkBrokerConfiguration) async throws

    /// Tears the session down. Safe to call when not connected.
    func disconnect() async

    /// Issues one active discovery request and ingests its responses.
    ///
    /// - Throws: ``GnosticTransportError`` when no session is running.
    func discover() async throws

    /// Observes catalog changes and connection loss for the lifetime of the transport.
    ///
    /// The returned stream is long-lived; a consumer iterates it until it cancels.
    func events() async -> AsyncStream<GnosticTransportEvent>
}
