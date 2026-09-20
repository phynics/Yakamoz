import Foundation
import Testing
@testable import YakamozNetwork

@Suite("NetworkClientSession")
@MainActor
struct NetworkClientSessionTests {
    private func makeConfiguration(enabled: Bool = true) -> NetworkBrokerConfiguration {
        NetworkBrokerConfiguration(
            host: "127.0.0.1",
            port: 1883,
            namespace: "gnostic",
            identity: "yakamoz",
            isEnabled: enabled
        )
    }

    private func makeSession(
        enabled: Bool = true,
        transport: FakeGnosticTransport,
        backoff: BackoffSchedule = BackoffSchedule(base: 0.01, factor: 2, cap: 1, jitter: 0),
        retryLimit: Int = 5,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> NetworkClientSession {
        NetworkClientSession(
            configuration: makeConfiguration(enabled: enabled),
            transport: transport,
            backoff: backoff,
            retryLimit: retryLimit,
            sleep: sleep
        )
    }

    /// Yields to the session's observation task until `condition` holds or the bounded
    /// deadline passes. Used only to observe the live event-stream glue.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("Start connects once and discovers on start")
    func connectAndDiscoverOnStart() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)

        await session.start()

        #expect(session.state == .online)
        let connects = await transport.connectCount
        let discovers = await transport.discoverCount
        #expect(connects == 1)
        #expect(discovers == 1)
        let configuration = await transport.lastConfiguration
        #expect(configuration?.namespace == "gnostic")
    }

    @Test("A disabled client never connects")
    func disabledDoesNotConnect() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(enabled: false, transport: transport)

        await session.start()

        #expect(session.state == .disabled)
        let connects = await transport.connectCount
        #expect(connects == 0)
    }

    @Test("Force refresh re-sends discover while online")
    func forceRefreshResendsDiscover() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()

        await session.forceRefresh()

        #expect(session.state == .online)
        let discovers = await transport.discoverCount
        #expect(discovers == 2)
    }

    @Test("Connect failures retry with backoff until online")
    func retriesWithBackoff() async {
        let transport = FakeGnosticTransport()
        await transport.failNextConnects(2)
        let recorder = DelayRecorder()
        let backoff = BackoffSchedule(base: 1, factor: 2, cap: 30, jitter: 0)
        let session = makeSession(
            transport: transport,
            backoff: backoff,
            sleep: { recorder.record($0) }
        )

        await session.start()

        #expect(session.state == .online)
        let connects = await transport.connectCount
        #expect(connects == 3)
        #expect(recorder.durations == [.seconds(1), .seconds(2)])
    }

    @Test("The retry limit ends in a failed state")
    func retryLimitReached() async {
        let transport = FakeGnosticTransport()
        await transport.failNextConnects(10)
        let recorder = DelayRecorder()
        let session = makeSession(
            transport: transport,
            backoff: BackoffSchedule(base: 0.01, factor: 2, cap: 1, jitter: 0),
            retryLimit: 3,
            sleep: { recorder.record($0) }
        )

        await session.start()

        #expect(session.state.failureMessage != nil)
        let connects = await transport.connectCount
        #expect(connects == 4)
        #expect(recorder.durations.count == 3)
    }

    @Test("A lost connection transitions through retrying back to online")
    func connectionLostReconnects() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()

        await session.ingest(.connectionLost(reason: "broker gone"))

        #expect(session.state == .online)
        let connects = await transport.connectCount
        let discovers = await transport.discoverCount
        #expect(connects == 2)
        #expect(discovers == 2)
    }

    @Test("Disabling via update disconnects the transport")
    func disableDisconnects() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()

        await session.update(configuration: makeConfiguration(enabled: false))

        #expect(session.state == .disabled)
        let disconnects = await transport.disconnectCount
        #expect(disconnects >= 1)
    }

    @Test("Enabling via update connects an already-started client")
    func enableConnects() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(enabled: false, transport: transport)
        await session.start()
        #expect(session.state == .disabled)

        await session.update(configuration: makeConfiguration(enabled: true))

        #expect(session.state == .online)
        let connects = await transport.connectCount
        #expect(connects == 1)
    }

    @Test("Catalog events are ingested from the transport")
    func ingestsCatalogEvents() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()
        let key = TestEntities.key(UUID())

        await session.ingest(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Ada"))))
        await session.ingest(.deadvertised(key))

        #expect(session.catalog.ascendants[key] == nil)
    }

    @Test("Advertise and deadvertise arrive through the live event stream")
    func observesEventStream() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()
        let key = TestEntities.key(UUID())

        await transport.emit(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Ada"))))
        await waitUntil { session.catalog.ascendants[key] != nil }
        #expect(session.catalog.ascendants[key] != nil)

        await transport.emit(.deadvertised(key))
        await waitUntil { session.catalog.ascendants[key] == nil }
        #expect(session.catalog.ascendants[key] == nil)
    }

    @Test("An open session is retained after the object is deadvertised")
    func openSessionRetainedAfterDeadvertise() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()
        let key = TestEntities.key(UUID())
        await session.ingest(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Ada"))))

        session.openSession(key)
        await session.ingest(.deadvertised(key))

        #expect(session.catalog.ascendants[key] == nil)
        #expect(session.openSessions[key] != nil)

        session.closeSession(key)
        #expect(session.openSessions[key] == nil)
    }

    @Test("Stop disconnects the transport and disables the session")
    func stopDisconnects() async {
        let transport = FakeGnosticTransport()
        let session = makeSession(transport: transport)
        await session.start()

        await session.stop()

        #expect(session.state == .disabled)
        let disconnects = await transport.disconnectCount
        #expect(disconnects == 1)
    }
}
