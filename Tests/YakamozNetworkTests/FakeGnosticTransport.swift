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

    private(set) var turnRequests: [GnosticTurnRequest] = []
    private(set) var permissionResponses: [RecordedPermissionResponse] = []
    private var turnContinuations: [UUID: AsyncStream<GnosticTurnEvent>.Continuation] = [:]
    private var turnFailuresRemaining = 0

    struct RecordedPermissionResponse: Equatable, Sendable {
        let correlationID: String
        let approved: Bool
        let request: GnosticTurnRequest
    }

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

    // MARK: - Turns

    func runTurn(_ request: GnosticTurnRequest) async throws -> AsyncStream<GnosticTurnEvent> {
        turnRequests.append(request)
        if turnFailuresRemaining > 0 {
            turnFailuresRemaining -= 1
            throw GnosticTransportError.turnUnavailable("scripted turn failure")
        }
        let pair = AsyncStream<GnosticTurnEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        turnContinuations[UUID()] = pair.continuation
        return pair.stream
    }

    func respondToPermission(
        correlationID: String,
        approved: Bool,
        request: GnosticTurnRequest
    ) async throws {
        permissionResponses.append(RecordedPermissionResponse(
            correlationID: correlationID,
            approved: approved,
            request: request
        ))
    }

    /// The next `count` runTurn calls throw.
    func failNextTurns(_ count: Int) {
        turnFailuresRemaining = count
    }

    /// Pushes one turn event to every live turn stream.
    func emitTurn(_ event: GnosticTurnEvent) {
        for continuation in turnContinuations.values {
            continuation.yield(event)
        }
    }

    /// Finishes every live turn stream without a terminal event (simulates a dropped
    /// connection mid-turn).
    func dropTurnStreams() {
        for continuation in turnContinuations.values {
            continuation.finish()
        }
        turnContinuations = [:]
    }

    /// Finishes every live turn stream.
    func finishTurnStreams() {
        for continuation in turnContinuations.values {
            continuation.finish()
        }
        turnContinuations = [:]
    }
}
