import Foundation
import MonadClient
import MonadShared
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// YAK-MON-3: exercises `MonadYakamozBackend`'s mapping/error-translation logic against a
/// fully in-memory fake `MonadClientTransport` — no `URLSession`, no real `MonadClient`,
/// no network. `MonadClient`'s streaming call returns a concrete `URLSession.AsyncBytes`
/// under the hood, which cannot be hand-constructed in a test double, so the fake sits at
/// the `MonadClientTransport` seam (one level above `MonadClient` itself) rather than at
/// `URLSessionProtocol`.
@Suite("MonadYakamozBackend")
struct MonadYakamozBackendTests {
    fileprivate actor FakeTransport: MonadClientTransport {
        var statusResult: Result<StatusResponse, Error> = .failure(MonadClientError.serverNotReachable)
        var timelines: [TimelineResponse] = []
        var createdTitle: String?
        var executeResult: Result<[ChatEvent], Error> = .success([])
        var lastExecuteRequest: (timelineId: UUID, message: String)?
        var getTimelineResult: ((UUID) -> Result<TimelineResponse, Error>)?

        func getStatus() async throws -> StatusResponse {
            try statusResult.get()
        }

        func listTimelines() async throws -> [TimelineResponse] {
            timelines
        }

        func createTimeline(title: String?) async throws -> TimelineResponse {
            createdTitle = title
            let timeline = TimelineResponse(id: UUID(), title: title)
            timelines.append(timeline)
            return timeline
        }

        func getTimeline(id: UUID) async throws -> TimelineResponse {
            guard let getTimelineResult else {
                if let match = timelines.first(where: { $0.id == id }) {
                    return match
                }
                throw MonadClientError.notFound
            }
            return try getTimelineResult(id).get()
        }

        func execute(
            timelineId: UUID,
            message: String,
            toolOutputs _: [ToolOutputSubmission]?,
            clientTools _: [ToolReference]?
        ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
            lastExecuteRequest = (timelineId, message)
            let events = try executeResult.get()
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Health

    @Test("healthy status maps to .ok")
    func healthOK() async {
        let transport = FakeTransport()
        await transport.setStatusResult(
            .success(StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:]))
        )
        let backend = MonadYakamozBackend(transport: transport)
        #expect(await backend.backendHealthCheck() == .ok)
    }

    @Test("degraded status maps to .degraded")
    func healthDegraded() async {
        let transport = FakeTransport()
        await transport.setStatusResult(
            .success(StatusResponse(status: .degraded, version: "1.0", uptime: 1, components: [:]))
        )
        let backend = MonadYakamozBackend(transport: transport)
        #expect(await backend.backendHealthCheck() == .degraded)
    }

    @Test("network error maps to .down and to a typed unreachable error")
    func healthUnreachable() async throws {
        let transport = FakeTransport()
        await transport.setStatusResult(.failure(MonadClientError.serverNotReachable))
        let backend = MonadYakamozBackend(transport: transport)

        #expect(await backend.backendHealthCheck() == .down)
        await #expect(throws: MonadBackendHealthError.self) {
            try await backend.verifyReachable()
        }
    }

    @Test("401 maps to .down and to a typed authentication error")
    func healthAuthFailure() async throws {
        let transport = FakeTransport()
        await transport.setStatusResult(.failure(MonadClientError.unauthorized))
        let backend = MonadYakamozBackend(transport: transport)

        #expect(await backend.backendHealthCheck() == .down)
        do {
            _ = try await backend.verifyReachable()
            Issue.record("expected verifyReachable to throw")
        } catch let error as MonadBackendHealthError {
            #expect(error == .authenticationFailed)
        }
    }

    @Test("an unexpected/decoding failure maps to a typed incompatible-response error")
    func healthIncompatibleResponse() async throws {
        let transport = FakeTransport()
        await transport.setStatusResult(.failure(MonadClientError.decodingError(DummyError())))
        let backend = MonadYakamozBackend(transport: transport)

        #expect(await backend.backendHealthCheck() == .down)
        do {
            _ = try await backend.verifyReachable()
            Issue.record("expected verifyReachable to throw")
        } catch let error as MonadBackendHealthError {
            guard case .incompatibleResponse = error else {
                Issue.record("expected .incompatibleResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - Timelines

    @Test("listTimelines maps TimelineResponse to BackendTimelineSummary")
    func listTimelinesMapsResponses() async throws {
        let transport = FakeTransport()
        let id = UUID()
        await transport.seedTimeline(TimelineResponse(id: id, title: "Hello"))
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listTimelines()
        #expect(summaries.map(\.id) == [id])
        #expect(summaries.map(\.title) == ["Hello"])
    }

    @Test("listTimelines falls back to a placeholder title when the server title is nil")
    func listTimelinesFallsBackTitle() async throws {
        let transport = FakeTransport()
        await transport.seedTimeline(TimelineResponse(id: UUID(), title: nil))
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listTimelines()
        #expect(summaries.first?.title == "Untitled")
    }

    @Test("createTimeline round-trips the requested title")
    func createTimelineRoundTrips() async throws {
        let transport = FakeTransport()
        let backend = MonadYakamozBackend(transport: transport)

        let summary = try await backend.createTimeline(title: "New timeline")
        #expect(summary.title == "New timeline")
        #expect(await transport.createdTitle == "New timeline")
    }

    @Test("loadTimeline returns nil for a not-found timeline instead of throwing")
    func loadTimelineNotFoundReturnsNil() async throws {
        let transport = FakeTransport()
        let backend = MonadYakamozBackend(transport: transport)

        let loaded = try await backend.loadTimeline(id: UUID())
        #expect(loaded == nil)
    }

    @Test("loadTimeline returns a summary for an existing timeline")
    func loadTimelineFound() async throws {
        let transport = FakeTransport()
        let id = UUID()
        await transport.seedTimeline(TimelineResponse(id: id, title: "Existing"))
        let backend = MonadYakamozBackend(transport: transport)

        let loaded = try await backend.loadTimeline(id: id)
        #expect(loaded?.id == id)
        #expect(loaded?.title == "Existing")
    }

    // MARK: - Chat streaming

    @Test("run() forwards the request to the transport and streams back its events")
    func runStreamsEvents() async throws {
        let transport = FakeTransport()
        await transport.setExecuteResult(.success([.delta(.generation(text: "Hi there"))]))
        let backend = MonadYakamozBackend(transport: transport)

        let timelineId = UUID()
        let request = ChatRunRequest(timelineId: timelineId, message: "Hello")
        let stream = try await backend.run(request)

        var received: [ChatEvent] = []
        for try await event in stream {
            received.append(event)
        }

        #expect(received.count == 1)
        #expect(received.first?.textContent == "Hi there")

        let lastRequest = await transport.lastExecuteRequest
        #expect(lastRequest?.timelineId == timelineId)
        #expect(lastRequest?.message == "Hello")
    }

    @Test("run() maps a transport error to a typed MonadBackendHealthError")
    func runMapsTransportError() async throws {
        let transport = FakeTransport()
        await transport.setExecuteResult(.failure(MonadClientError.unauthorized))
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            _ = try await backend.run(ChatRunRequest(timelineId: UUID(), message: "Hello"))
        }
    }
}

private struct DummyError: Error {}

private extension MonadYakamozBackendTests.FakeTransport {
    func setStatusResult(_ result: Result<StatusResponse, Error>) {
        statusResult = result
    }

    func seedTimeline(_ timeline: TimelineResponse) {
        timelines.append(timeline)
    }

    func setExecuteResult(_ result: Result<[ChatEvent], Error>) {
        executeResult = result
    }
}
