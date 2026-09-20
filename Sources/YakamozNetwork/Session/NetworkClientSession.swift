import Foundation
import Logging
import Observation
import YakamozCore

/// Owns the Gnostic connection lifecycle, discovery, and live catalog.
///
/// The session is `@MainActor` and drives a `Sendable` ``GnosticClientTransport``.
/// Its only channel to the transport is the `events()` stream plus the async
/// `connect`/`discover` calls, so the state machine is deterministic and testable
/// against an offline fake. Network entities are presentation state only: the
/// session never creates an `AgentModel`/`ConversationModel` row (ADR 0002).
@MainActor
@Observable
public final class NetworkClientSession {
    /// The current connection lifecycle state.
    public private(set) var state: NetworkConnectionState
    /// The live, reduced catalog of discovered objects.
    public private(set) var catalog: NetworkCatalogState
    /// Objects the user has opened, retained as last-known snapshots so a
    /// deadvertised entry can still render as offline/reconnectable until closed.
    public private(set) var openSessions: [NetworkObjectKey: DiscoveredNetworkObject]
    /// The broker configuration currently in effect.
    public private(set) var configuration: NetworkBrokerConfiguration

    private let transport: any GnosticClientTransport
    private let backoff: BackoffSchedule
    private let retryLimit: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var observationTask: Task<Void, Never>?
    private var hasStarted = false

    public init(
        configuration: NetworkBrokerConfiguration,
        transport: any GnosticClientTransport,
        backoff: BackoffSchedule = BackoffSchedule(),
        retryLimit: Int = 5,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.backoff = backoff
        self.retryLimit = max(0, retryLimit)
        self.sleep = sleep
        self.now = now
        state = .disabled
        catalog = NetworkCatalogState()
        openSessions = [:]
    }

    // MARK: - Lifecycle

    /// Begins observing transport events and, when enabled, connects immediately.
    ///
    /// Safe to call more than once; only the first call starts observation.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        let stream = await transport.events()
        observationTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.ingest(event)
            }
        }

        guard configuration.isEnabled else {
            state = .disabled
            return
        }
        await connectLoop(startAttempt: 0)
    }

    /// Stops observation and tears the transport down.
    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        await transport.disconnect()
        state = .disabled
    }

    /// Applies a new configuration, connecting or disconnecting on an enable/disable edge.
    ///
    /// While already enabled, field edits are held until the client is disabled and
    /// re-enabled (or the app relaunches), which avoids reconnecting on every keystroke.
    public func update(configuration newValue: NetworkBrokerConfiguration) async {
        guard newValue != configuration else { return }
        let wasEnabled = configuration.isEnabled
        configuration = newValue

        guard newValue.isEnabled else {
            if wasEnabled {
                await transport.disconnect()
            }
            state = .disabled
            return
        }

        guard !wasEnabled else { return }
        if hasStarted {
            await connectLoop(startAttempt: 0)
        } else {
            await start()
        }
    }

    /// Re-sends discovery while online, leaving the session connected.
    public func forceRefresh() async {
        guard state.isOnline else { return }
        do {
            try await transport.discover()
        } catch {
            Log.network.error("network force refresh failed: \(error)")
        }
    }

    // MARK: - Open sessions

    /// Retains the current snapshot of `key` as an open session.
    public func openSession(_ key: NetworkObjectKey) {
        guard let object = catalog.object(for: key) ?? openSessions[key] else { return }
        openSessions[key] = object
    }

    /// Releases an open session; a deadvertised object then leaves the browser.
    public func closeSession(_ key: NetworkObjectKey) {
        openSessions[key] = nil
    }

    // MARK: - Event ingestion

    /// Reduces one transport event into session state.
    ///
    /// Exposed to the test target so the retry path can be driven without a broker.
    func ingest(_ event: GnosticTransportEvent) async {
        switch event {
        case .discovered, .deadvertised, .providerEvicted:
            catalog.apply(event)
        case let .connectionLost(reason):
            guard configuration.isEnabled else { return }
            Log.network.error("network connection lost: \(reason)")
            await connectLoop(startAttempt: 1)
        }
    }

    // MARK: - Connection

    private func connectLoop(startAttempt: Int) async {
        var attempt = startAttempt
        while configuration.isEnabled {
            if attempt > 0 {
                let delay = backoff.delay(forAttempt: attempt)
                state = .retrying(
                    attempt: attempt,
                    nextAttemptAt: now().addingTimeInterval(backoff.delaySeconds(forAttempt: attempt))
                )
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard configuration.isEnabled else {
                    state = .disabled
                    return
                }
            } else {
                state = .connecting
            }

            do {
                try await transport.connect(configuration)
                state = .online
                do {
                    try await transport.discover()
                } catch {
                    Log.network.error("network discover-on-start failed: \(error)")
                }
                return
            } catch {
                attempt += 1
                if attempt > retryLimit {
                    state = .failed(String(describing: error))
                    return
                }
            }
        }
        state = .disabled
    }
}
