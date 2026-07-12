import Foundation
import MonadClient
import MonadShared
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// YAK-MON-11: exercises `MonadTimelineBrowsingViewModel` against a fully in-memory fake
/// `MonadClientTransport` (via `MonadYakamozBackend`) — no network, no real `MonadClient`,
/// mirroring the `FakeTransport` pattern from `MonadYakamozBackendTests`.
@Suite("MonadTimelineBrowsingViewModel")
@MainActor
struct MonadTimelineBrowsingTests {
    fileprivate actor FakeTransport: MonadClientTransport {
        var timelines: [TimelineResponse] = []
        var createdTitle: String?
        var createTimelineError: Error?
        var listTimelinesResult: Result<[TimelineResponse], Error>?

        func getStatus() async throws -> StatusResponse {
            StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])
        }

        func listTimelines() async throws -> [TimelineResponse] {
            if let listTimelinesResult {
                return try listTimelinesResult.get()
            }
            return timelines
        }

        func createTimeline(title: String?) async throws -> TimelineResponse {
            if let createTimelineError {
                throw createTimelineError
            }
            createdTitle = title
            let timeline = TimelineResponse(id: UUID(), title: title)
            timelines.append(timeline)
            return timeline
        }

        func getTimeline(id: UUID) async throws -> TimelineResponse {
            if let match = timelines.first(where: { $0.id == id }) {
                return match
            }
            throw MonadClientError.notFound
        }

        func execute(
            timelineId _: UUID,
            message _: String,
            toolOutputs _: [ToolOutputSubmission]?,
            clientTools _: [ToolReference]?
        ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func listAgentInstances() async throws -> [AgentInstance] { [] }
        func listAgentTemplates() async throws -> [AgentTemplate] { [] }
        func getAgentTimelines(agentId _: UUID) async throws -> [TimelineResponse] { [] }

        func listWorkspaces() async throws -> [WorkspaceReference] { [] }
        func attachWorkspace(_: UUID, to _: UUID) async throws {}
        func detachWorkspace(_: UUID, from _: UUID) async throws {}
        func listTimelineWorkspaces(timelineId _: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
            (primary: nil, attached: [])
        }

        // MARK: - Helpers

        func seedTimeline(_ timeline: TimelineResponse) {
            timelines.append(timeline)
        }

        func setListTimelinesResult(_ result: Result<[TimelineResponse], Error>?) {
            listTimelinesResult = result
        }

        func setCreateTimelineError(_ error: Error?) {
            createTimelineError = error
        }
    }

    private struct FakeSecretStore: SecretStoring {
        func read(account _: String) throws -> String? { nil }
        func write(_: String, account _: String) throws {}
        func delete(account _: String) throws {}
    }

    private func makeProfile() -> MonadProfile {
        MonadProfile(displayName: "Test", serverURL: URL(string: "http://127.0.0.1:8080")!)
    }

    private func makeVM(transport: FakeTransport) -> MonadTimelineBrowsingViewModel {
        MonadTimelineBrowsingViewModel(
            profile: makeProfile(),
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in
                MonadYakamozBackend(transport: transport)
            }
        )
    }

    // MARK: - load()

    @Test("load populates timelines from the server")
    func loadPopulatesTimelines() async throws {
        let transport = FakeTransport()
        let id = UUID()
        await transport.seedTimeline(TimelineResponse(id: id, title: "Project Planning"))

        let vm = makeVM(transport: transport)
        await vm.load()

        #expect(vm.loadState == .loaded)
        #expect(vm.timelines.count == 1)
        #expect(vm.timelines.first?.id == id)
        #expect(vm.timelines.first?.title == "Project Planning")
    }

    @Test("load with no server timelines produces an empty loaded list")
    func loadEmptyTimelines() async {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        await vm.load()

        #expect(vm.loadState == .loaded)
        #expect(vm.timelines.isEmpty)
    }

    @Test("load surfaces a failed state on transport error")
    func loadSurfacesError() async throws {
        let transport = FakeTransport()
        await transport.setListTimelinesResult(.failure(MonadClientError.unauthorized))

        let vm = makeVM(transport: transport)
        await vm.load()

        if case .failed = vm.loadState {
            // expected
        } else {
            Issue.record("expected .failed state, got \(vm.loadState)")
        }
        #expect(vm.timelines.isEmpty)
    }

    @Test("load maps an unreachable transport to a user-friendly error message")
    func loadUnreachableMessage() async throws {
        let transport = FakeTransport()
        await transport.setListTimelinesResult(.failure(MonadClientError.serverNotReachable))

        let vm = makeVM(transport: transport)
        await vm.load()

        guard case let .failed(message) = vm.loadState else {
            Issue.record("expected .failed state")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: - createTimeline()

    @Test("createTimeline creates a timeline and refreshes the list so the new timeline appears")
    func createTimelineRefreshesList() async throws {
        let transport = FakeTransport()
        await transport.seedTimeline(TimelineResponse(id: UUID(), title: "Existing"))

        let vm = makeVM(transport: transport)
        await vm.load()
        #expect(vm.timelines.count == 1)

        let created = await vm.createTimeline(title: "New Timeline")

        #expect(created?.title == "New Timeline")
        #expect(vm.timelines.count == 2)
        #expect(vm.timelines.last?.title == "New Timeline")
        #expect(await transport.createdTitle == "New Timeline")
    }

    @Test("createTimeline returns the created timeline summary with a valid id")
    func createTimelineReturnsSummary() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        let created = await vm.createTimeline(title: "Fresh Timeline")

        let summary = try #require(created)
        #expect(summary.title == "Fresh Timeline")
        #expect(vm.timelines.contains { $0.id == summary.id })
    }

    @Test("createTimeline on an empty server produces a list with the new timeline")
    func createTimelineOnEmptyServer() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        await vm.load()
        #expect(vm.timelines.isEmpty)

        let created = await vm.createTimeline(title: "First Timeline")

        #expect(created != nil)
        #expect(vm.timelines.count == 1)
        #expect(vm.timelines.first?.title == "First Timeline")
    }

    @Test("createTimeline surfaces an action error on transport failure")
    func createTimelineSurfacesError() async throws {
        let transport = FakeTransport()
        await transport.seedTimeline(TimelineResponse(id: UUID(), title: "Pre-existing"))

        let vm = makeVM(transport: transport)
        await vm.load()
        #expect(vm.loadState == .loaded)

        await transport.setCreateTimelineError(MonadClientError.unauthorized)

        let created = await vm.createTimeline(title: "Should Fail")

        #expect(created == nil)
        #expect(vm.isCreating == false)
        #expect(vm.actionError != nil)
        #expect(vm.loadState == .loaded)
    }

    @Test("createTimeline maps an auth failure to a user-friendly error message")
    func createTimelineAuthErrorMessage() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        await transport.setCreateTimelineError(MonadClientError.unauthorized)

        let created = await vm.createTimeline(title: "No Auth")

        #expect(created == nil)
        #expect(vm.actionError != nil)
        #expect(!vm.actionError!.isEmpty)
    }

    @Test("createTimeline maps an unreachable transport to a user-friendly error message")
    func createTimelineUnreachableMessage() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        await transport.setCreateTimelineError(MonadClientError.serverNotReachable)

        let created = await vm.createTimeline(title: "No Server")

        #expect(created == nil)
        #expect(vm.actionError != nil)
        #expect(!vm.actionError!.isEmpty)
    }

    // MARK: - isCreating state

    @Test("isCreating is false before and after a successful create")
    func isCreatingStateOnSuccess() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        #expect(vm.isCreating == false)

        _ = await vm.createTimeline(title: "Test")

        #expect(vm.isCreating == false)
    }

    @Test("isCreating is false after a failed create")
    func isCreatingStateOnFailure() async throws {
        let transport = FakeTransport()
        await transport.setCreateTimelineError(MonadClientError.serverNotReachable)
        let vm = makeVM(transport: transport)

        _ = await vm.createTimeline(title: "Fails")

        #expect(vm.isCreating == false)
    }

    // MARK: - actionError lifecycle

    @Test("a successful createTimeline clears a stale actionError from a previous failure")
    func createTimelineClearsStaleError() async throws {
        let transport = FakeTransport()
        let vm = makeVM(transport: transport)

        await transport.setCreateTimelineError(MonadClientError.unauthorized)
        _ = await vm.createTimeline(title: "Fails")
        #expect(vm.actionError != nil)

        await transport.setCreateTimelineError(nil)
        _ = await vm.createTimeline(title: "After Recovery")

        #expect(vm.actionError == nil)
        #expect(vm.loadState == .loaded)
        #expect(vm.timelines.count == 1)
    }

    @Test("load clears a stale actionError from a previous create failure")
    func loadClearsActionError() async throws {
        let transport = FakeTransport()
        await transport.setCreateTimelineError(MonadClientError.unauthorized)
        let vm = makeVM(transport: transport)

        _ = await vm.createTimeline(title: "Fails")
        #expect(vm.actionError != nil)

        await transport.setCreateTimelineError(nil)
        await vm.load()

        #expect(vm.actionError == nil)
        #expect(vm.loadState == .loaded)
    }

    // MARK: - multiple timelines

    @Test("createTimeline appends to an existing list without losing prior timelines")
    func createTimelineAppendsToList() async throws {
        let transport = FakeTransport()
        await transport.seedTimeline(TimelineResponse(id: UUID(), title: "First"))
        await transport.seedTimeline(TimelineResponse(id: UUID(), title: "Second"))

        let vm = makeVM(transport: transport)
        await vm.load()
        #expect(vm.timelines.count == 2)

        _ = await vm.createTimeline(title: "Third")

        #expect(vm.timelines.count == 3)
        #expect(vm.timelines.last?.title == "Third")
        #expect(vm.timelines.first?.title == "First")
    }
}
