import Foundation
import PKContracts
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// YAK-MON-2: exercises the `YakamozBackend` seam itself — a fully in-memory fake
/// conforming to the composed protocol (no `LocalYakamozBackend`, no `YakamozRuntime`,
/// no network) — proving the protocols are narrow enough to fake end to end, and that
/// `LocalYakamozBackend` satisfies the same seam.
@Suite("YakamozBackend seam")
struct YakamozBackendSeamTests {
    /// A minimal in-memory fake backend: no SwiftData, no `YakamozRuntime`, no network.
    private actor FakeBackend: YakamozBackend {
        var timelines: [BackendTimelineSummary] = []
        var agents: [BackendAgentSummary] = []
        var workspaces: [BackendWorkspaceSummary] = []
        var selectedAgentByTimeline: [UUID: UUID?] = [:]
        var attachedWorkspacesByTimeline: [UUID: Set<UUID>] = [:]
        var lastRunRequest: TurnRequest?
        let inspectorAvailable = true

        func backendHealthCheck() async -> AppHealthStatus {
            .ok
        }

        func run(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
            lastRunRequest = request
            return AsyncThrowingStream { $0.finish() }
        }

        func listTimelines() async throws -> [BackendTimelineSummary] {
            timelines
        }

        func createTimeline(title: String) async throws -> BackendTimelineSummary {
            let summary = BackendTimelineSummary(id: UUID(), title: title, createdAt: .now)
            timelines.append(summary)
            return summary
        }

        func loadTimeline(id: UUID) async throws -> BackendTimelineSummary? {
            timelines.first { $0.id == id }
        }

        func listAgents() async throws -> [BackendAgentSummary] {
            agents
        }

        func selectAgent(_ agentId: UUID?, forTimeline timelineId: UUID) async throws {
            selectedAgentByTimeline[timelineId] = agentId
        }

        func listWorkspaces() async throws -> [BackendWorkspaceSummary] {
            workspaces
        }

        func attachWorkspace(_ workspaceId: UUID, toTimeline timelineId: UUID) async throws {
            attachedWorkspacesByTimeline[timelineId, default: []].insert(workspaceId)
        }

        func detachWorkspace(_ workspaceId: UUID, fromTimeline timelineId: UUID) async throws {
            attachedWorkspacesByTimeline[timelineId]?.remove(workspaceId)
        }
    }

    @Test("a fake YakamozBackend can be driven end to end with no network and no YakamozRuntime")
    func fakeBackendDrivesFullSurface() async throws {
        let backend: any YakamozBackend = FakeBackend()

        #expect(await backend.backendHealthCheck() == .ok)
        #expect(await backend.inspectorAvailable)

        let timeline = try await backend.createTimeline(title: "Hello")
        #expect(timeline.title == "Hello")
        let listed = try await backend.listTimelines()
        #expect(listed.map(\.id) == [timeline.id])
        let loaded = try await backend.loadTimeline(id: timeline.id)
        #expect(loaded?.id == timeline.id)
        let missing = try await backend.loadTimeline(id: UUID())
        #expect(missing == nil)

        let agentId = UUID()
        try await backend.selectAgent(agentId, forTimeline: timeline.id)

        let workspaceId = UUID()
        try await backend.attachWorkspace(workspaceId, toTimeline: timeline.id)
        try await backend.detachWorkspace(workspaceId, fromTimeline: timeline.id)

        let stream = try await backend.run(TurnRequest(threadID: timeline.id, message: "hi", tools: []))
        var events: [TurnEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events.isEmpty)
    }
}

/// `LocalYakamozBackend` wraps `ConversationCoordinator`/SwiftData behavior behind the
/// seam. Every test here uses a scripted `ChatRunning`/`BackendHealthChecking` fake and
/// an in-memory `ModelContainer` — never a real `YakamozRuntime` and never a network call
/// — proving the local adapter faithfully wraps existing behavior in isolation.
@Suite("LocalYakamozBackend")
@MainActor
struct LocalYakamozBackendTests {
    private final class ScriptedRunner: ChatRunning, @unchecked Sendable {
        private(set) var capturedRequests: [TurnRequest] = []

        func run(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
            capturedRequests.append(request)
            return AsyncThrowingStream { $0.finish() }
        }
    }

    private struct ScriptedHealth: BackendHealthChecking {
        let status: AppHealthStatus
        func backendHealthCheck() async -> AppHealthStatus {
            status
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(YakamozSchema.models), configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeBackend(
        container: ModelContainer,
        runner: ScriptedRunner = ScriptedRunner(),
        health: AppHealthStatus = .ok
    ) -> LocalYakamozBackend {
        let stores = YakamozStores(modelContainer: container)
        return LocalYakamozBackend(
            chatRunner: runner,
            health: ScriptedHealth(status: health),
            modelContainer: container,
            timelineStore: stores.timelines
        )
    }

    @Test("backendHealthCheck delegates to the injected health collaborator")
    func healthCheckDelegates() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container, health: .degraded)
        #expect(await backend.backendHealthCheck() == .degraded)
    }

    @Test("run delegates to the injected chat runner, not a real YakamozRuntime")
    func runDelegatesToScriptedRunner() async throws {
        let container = try makeContainer()
        let runner = ScriptedRunner()
        let backend = makeBackend(container: container, runner: runner)

        let timelineId = UUID()
        let request = TurnRequest(threadID: timelineId, message: "hello", tools: [])
        _ = try await backend.run(request)

        #expect(runner.capturedRequests.count == 1)
        #expect(runner.capturedRequests.first?.threadID == timelineId)
        #expect(runner.capturedRequests.first?.message == "hello")
    }

    @Test("createTimeline persists a paired ConversationModel/Timeline and listTimelines reflects it")
    func createAndListTimelines() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)

        let created = try await backend.createTimeline(title: "Project Kickoff")
        #expect(created.title == "Project Kickoff")
        #expect(!created.isHomeTimeline)

        let listed = try await backend.listTimelines()
        #expect(listed.map(\.id) == [created.id])
        #expect(listed.first?.title == "Project Kickoff")
    }

    @Test("loadTimeline returns the matching summary, nil when absent")
    func loadTimeline() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)

        let created = try await backend.createTimeline(title: "Loadable")
        let loaded = try await backend.loadTimeline(id: created.id)
        #expect(loaded?.id == created.id)
        #expect(loaded?.title == "Loadable")

        let missing = try await backend.loadTimeline(id: UUID())
        #expect(missing == nil)
    }

    @Test("listAgents reflects persisted AgentModel rows")
    func listAgents() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)
        let agent = AgentModel(name: "Ada", instructions: "", vaultPath: "/tmp/ada")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        let agents = try await backend.listAgents()
        #expect(agents.map(\.id) == [agent.id])
        #expect(agents.first?.name == "Ada")
    }

    @Test("selectAgent assigns the operator on the timeline via ConversationCoordinator")
    func selectAgentAssignsOperator() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)
        let agent = AgentModel(name: "Ada", instructions: "", vaultPath: "/tmp/ada")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        let timeline = try await backend.createTimeline(title: "Needs Operator")
        try await backend.selectAgent(agent.id, forTimeline: timeline.id)

        let timelineId = timeline.id
        var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineId })
        descriptor.fetchLimit = 1
        let conversation = try #require(try container.mainContext.fetch(descriptor).first)
        #expect(conversation.agentId == agent.id)
    }

    @Test("listWorkspaces reflects persisted WorkspaceModel rows")
    func listWorkspaces() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)
        let workspace = WorkspaceModel(displayName: "Repo", folderPath: "/tmp/repo")
        container.mainContext.insert(workspace)
        try container.mainContext.save()

        let workspaces = try await backend.listWorkspaces()
        #expect(workspaces.map(\.id) == [workspace.id])
        #expect(workspaces.first?.displayName == "Repo")
    }

    @Test("attachWorkspace/detachWorkspace mutate the timeline's attachedWorkspaceIds")
    func attachAndDetachWorkspace() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)
        let timeline = try await backend.createTimeline(title: "Attach Target")
        let workspaceId = UUID()

        try await backend.attachWorkspace(workspaceId, toTimeline: timeline.id)
        let timelineId = timeline.id
        var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineId })
        descriptor.fetchLimit = 1
        var conversation = try #require(try container.mainContext.fetch(descriptor).first)
        #expect(conversation.attachedWorkspaceIds == [workspaceId])

        try await backend.detachWorkspace(workspaceId, fromTimeline: timeline.id)
        conversation = try #require(try container.mainContext.fetch(descriptor).first)
        #expect(conversation.attachedWorkspaceIds.isEmpty)
    }

    @Test("attachWorkspace throws LocalBackendError.timelineNotFound for an unknown timeline")
    func attachWorkspaceUnknownTimeline() async throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)

        await #expect(throws: LocalBackendError.timelineNotFound) {
            try await backend.attachWorkspace(UUID(), toTimeline: UUID())
        }
    }

    @Test("inspectorAvailable defaults to true for local mode")
    func inspectorAvailableDefaultsTrue() throws {
        let container = try makeContainer()
        let backend = makeBackend(container: container)
        #expect(backend.inspectorAvailable)
    }
}
