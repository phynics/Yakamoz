import Foundation
import YakamozNetwork

/// Scriptable offline ``GnosticClientTransport``. Drives every session test with
/// no broker: connect/discover can be made to fail N times, counts are exposed,
/// and events are pushed through a single buffered stream.
actor FakeGnosticTransport: GnosticClientTransport {
    private let stream: AsyncStream<GnosticTransportEvent>
    private let continuation: AsyncStream<GnosticTransportEvent>.Continuation

    private(set) var connectCount = 0
    private(set) var discoverCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastConfiguration: NetworkBrokerConfiguration?

    private var connectFailuresRemaining = 0
    private var discoverFailuresRemaining = 0
    private var shouldGateConnect = false
    private var connectGate: CheckedContinuation<Void, Never>?

    init() {
        let pair = AsyncStream<GnosticTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() async -> AsyncStream<GnosticTransportEvent> {
        stream
    }

    func connect(_ configuration: NetworkBrokerConfiguration) async throws {
        connectCount += 1
        lastConfiguration = configuration
        if shouldGateConnect {
            shouldGateConnect = false
            await withCheckedContinuation { continuation in
                connectGate = continuation
            }
        }
        if connectFailuresRemaining > 0 {
            connectFailuresRemaining -= 1
            throw GnosticTransportError.connectionFailed("scripted connect failure")
        }
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func discover() async throws {
        discoverCount += 1
        if discoverFailuresRemaining > 0 {
            discoverFailuresRemaining -= 1
            throw GnosticTransportError.connectionFailed("scripted discover failure")
        }
    }

    /// Makes the next `connect` suspend until ``releaseConnect()`` is called.
    func gateNextConnect() {
        shouldGateConnect = true
    }

    /// Resumes a `connect` suspended by ``gateNextConnect()``.
    func releaseConnect() {
        connectGate?.resume()
        connectGate = nil
    }

    /// The next `count` connect attempts throw.
    func failNextConnects(_ count: Int) {
        connectFailuresRemaining = count
    }

    /// The next `count` discover attempts throw.
    func failNextDiscovers(_ count: Int) {
        discoverFailuresRemaining = count
    }

    /// Pushes one event to observers.
    func emit(_ event: GnosticTransportEvent) {
        continuation.yield(event)
    }
}
