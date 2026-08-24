import Foundation
import MonadClient
import MonadShared
import PKContracts
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
        var executeResult: Result<[TurnEvent], Error> = .success([])
        var lastExecuteRequest: (
            timelineId: UUID,
            message: String,
            toolOutputs: [ToolOutputSubmission]?,
            clientTools: [ToolReference]?
        )?
        var getTimelineResult: ((UUID) -> Result<TimelineResponse, Error>)?
        var agentInstancesResult: Result<[AgentInstance], Error> = .success([])
        var agentTemplatesResult: Result<[AgentTemplate], Error> = .success([])
        var agentTimelinesResult: Result<[TimelineResponse], Error> = .success([])
        var lastAgentTimelinesRequest: UUID?

        var allWorkspaces: [WorkspaceReference] = []
        var timelineWorkspaces: [UUID: (primary: WorkspaceReference?, attached: [WorkspaceReference])] = [:]
        var attachedWorkspaceIds: [UUID: [UUID]] = [:]
        var lastAttachRequest: (workspaceId: UUID, timelineId: UUID)?
        var lastDetachRequest: (workspaceId: UUID, timelineId: UUID)?
        var workspacesResult: Result<[WorkspaceReference], Error> = .success([])
        var timelineWorkspacesResult: ((UUID) -> Result<(primary: WorkspaceReference?, attached: [WorkspaceReference]), Error>)?
        var attachError: Error?
        var detachError: Error?

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
            toolOutputs: [ToolOutputSubmission]?,
            clientTools: [ToolReference]?
        ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
            lastExecuteRequest = (timelineId, message, toolOutputs, clientTools)
            let events = try executeResult.get()
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func listAgentInstances() async throws -> [AgentInstance] {
            try agentInstancesResult.get()
        }

        func listAgentTemplates() async throws -> [AgentTemplate] {
            try agentTemplatesResult.get()
        }

        func getAgentTimelines(agentId: UUID) async throws -> [TimelineResponse] {
            lastAgentTimelinesRequest = agentId
            return try agentTimelinesResult.get()
        }

        // MARK: - YAK-MON-6: workspace methods

        func listWorkspaces() async throws -> [WorkspaceReference] {
            if case let .failure(error) = workspacesResult { throw error }
            return allWorkspaces
        }

        func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
            if let attachError { throw attachError }
            lastAttachRequest = (workspaceId, timelineId)
            var ids = attachedWorkspaceIds[timelineId] ?? []
            if !ids.contains(workspaceId) { ids.append(workspaceId) }
            attachedWorkspaceIds[timelineId] = ids

            if let workspace = allWorkspaces.first(where: { $0.id == workspaceId }) {
                var entry = timelineWorkspaces[timelineId] ?? (primary: nil, attached: [])
                entry.attached.append(workspace)
                timelineWorkspaces[timelineId] = entry
            }
        }

        func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
            if let detachError { throw detachError }
            lastDetachRequest = (workspaceId, timelineId)
            var ids = attachedWorkspaceIds[timelineId] ?? []
            ids.removeAll { $0 == workspaceId }
            attachedWorkspaceIds[timelineId] = ids

            if var entry = timelineWorkspaces[timelineId] {
                entry.attached.removeAll { $0.id == workspaceId }
                timelineWorkspaces[timelineId] = entry
            }
        }

        func listTimelineWorkspaces(timelineId: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
            if let result = timelineWorkspacesResult {
                return try result(timelineId).get()
            }
            return timelineWorkspaces[timelineId] ?? (primary: nil, attached: [])
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
        let request = TurnRequest(timelineId: timelineId, message: "Hello")
        let stream = try await backend.run(request)

        var received: [TurnEvent] = []
        for try await event in stream {
            received.append(event)
        }

        #expect(received.count == 1)
        #expect(received.first?.textContent == "Hi there")

        let lastRequest = await transport.lastExecuteRequest
        #expect(lastRequest?.timelineId == timelineId)
        #expect(lastRequest?.message == "Hello")
    }

    @Test("run() preserves deferred workspace tool outputs and does not inject client tools")
    func runForwardsDeferredWorkspaceToolOutputs() async throws {
        let transport = FakeTransport()
        let backend = MonadYakamozBackend(transport: transport)
        let toolOutput = ToolOutputSubmission(toolCallID: "workspace-call", output: "README contents")

        _ = try await backend.run(
            TurnRequest(
                timelineId: UUID(),
                message: "Continue after the workspace result.",
                toolOutputs: [toolOutput]
            )
        )

        let recorded = await transport.lastExecuteRequest
        #expect(recorded?.toolOutputs?.count == 1)
        #expect(recorded?.toolOutputs?.first?.toolCallID == "workspace-call")
        #expect(recorded?.toolOutputs?.first?.output == "README contents")
        #expect(recorded?.clientTools == nil)
    }

    @Test("run() maps a transport error to a typed MonadBackendHealthError")
    func runMapsTransportError() async throws {
        let transport = FakeTransport()
        await transport.setExecuteResult(.failure(MonadClientError.unauthorized))
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            _ = try await backend.run(TurnRequest(timelineId: UUID(), message: "Hello"))
        }
    }

    // MARK: - Agent instances/templates (YAK-MON-4)

    @Test("listAgentInstances maps AgentInstance to MonadAgentSummary with .instance kind")
    func listAgentInstancesMaps() async throws {
        let transport = FakeTransport()
        let instance = AgentInstance(name: "Coder", description: "Writes code", privateTimelineId: UUID())
        await transport.setAgentInstancesResult(.success([instance]))
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listAgentInstances()
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == instance.id)
        #expect(summaries.first?.name == "Coder")
        #expect(summaries.first?.description == "Writes code")
        #expect(summaries.first?.kind == .instance)
    }

    @Test("listAgentTemplates maps AgentTemplate to MonadAgentSummary with .template kind")
    func listAgentTemplatesMaps() async throws {
        let transport = FakeTransport()
        let template = AgentTemplate(id: UUID(), name: "Default", description: "General purpose", systemPrompt: "Be helpful")
        await transport.setAgentTemplatesResult(.success([template]))
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listAgentTemplates()
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == template.id)
        #expect(summaries.first?.name == "Default")
        #expect(summaries.first?.kind == .template)
    }

    @Test("listAgentInstances maps a transport error to a typed MonadBackendHealthError")
    func listAgentInstancesMapsError() async throws {
        let transport = FakeTransport()
        await transport.setAgentInstancesResult(.failure(MonadClientError.unauthorized))
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            _ = try await backend.listAgentInstances()
        }
    }

    @Test("listTimelines(forAgent:) forwards the agent id and maps responses")
    func listTimelinesForAgentMaps() async throws {
        let transport = FakeTransport()
        let agentId = UUID()
        let timelineId = UUID()
        await transport.setAgentTimelinesResult(.success([TimelineResponse(id: timelineId, title: "Agent timeline")]))
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listTimelines(forAgent: agentId)
        #expect(summaries.map(\.id) == [timelineId])
        #expect(summaries.map(\.title) == ["Agent timeline"])
        #expect(await transport.lastAgentTimelinesRequest == agentId)
    }

    // MARK: - Workspace management (YAK-MON-6)

    @Test("listWorkspaces maps WorkspaceReference to BackendWorkspaceSummary using rootPath")
    func listWorkspacesMapsRootPath() async throws {
        let transport = FakeTransport()
        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/Users/dev/project"),
            location: .attached,
            rootPath: "/Users/dev/project"
        )
        await transport.seedWorkspace(workspace)
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listWorkspaces()
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == workspace.id)
        #expect(summaries.first?.displayName == "project")
    }

    @Test("listWorkspaces falls back to URI path when rootPath is nil")
    func listWorkspacesFallsBackToURI() async throws {
        let transport = FakeTransport()
        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/Users/dev/another"),
            location: .attached,
            rootPath: nil
        )
        await transport.seedWorkspace(workspace)
        let backend = MonadYakamozBackend(transport: transport)

        let summaries = try await backend.listWorkspaces()
        #expect(summaries.first?.displayName == "another")
    }

    @Test("listWorkspaces maps a transport error to a typed MonadBackendHealthError")
    func listWorkspacesMapsError() async throws {
        let transport = FakeTransport()
        await transport.setWorkspacesResult(.failure(MonadClientError.unauthorized))
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            _ = try await backend.listWorkspaces()
        }
    }

    @Test("attachWorkspace forwards the workspace and timeline ids to the transport")
    func attachWorkspaceForwards() async throws {
        let transport = FakeTransport()
        let workspaceId = UUID()
        let timelineId = UUID()
        let backend = MonadYakamozBackend(transport: transport)

        try await backend.attachWorkspace(workspaceId, toTimeline: timelineId)

        let lastAttach = await transport.lastAttachRequest
        #expect(lastAttach?.workspaceId == workspaceId)
        #expect(lastAttach?.timelineId == timelineId)
    }

    @Test("attachWorkspace maps a transport error to a typed MonadBackendHealthError")
    func attachWorkspaceMapsError() async throws {
        let transport = FakeTransport()
        await transport.setAttachError(MonadClientError.unauthorized)
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            try await backend.attachWorkspace(UUID(), toTimeline: UUID())
        }
    }

    @Test("detachWorkspace forwards the workspace and timeline ids to the transport")
    func detachWorkspaceForwards() async throws {
        let transport = FakeTransport()
        let workspaceId = UUID()
        let timelineId = UUID()
        let backend = MonadYakamozBackend(transport: transport)

        try await backend.detachWorkspace(workspaceId, fromTimeline: timelineId)

        let lastDetach = await transport.lastDetachRequest
        #expect(lastDetach?.workspaceId == workspaceId)
        #expect(lastDetach?.timelineId == timelineId)
    }

    @Test("detachWorkspace maps a transport error to a typed MonadBackendHealthError")
    func detachWorkspaceMapsError() async throws {
        let transport = FakeTransport()
        await transport.setDetachError(MonadClientError.unauthorized)
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            try await backend.detachWorkspace(UUID(), fromTimeline: UUID())
        }
    }

    @Test("listTimelineWorkspaces returns the primary and attached workspaces from the server")
    func listTimelineWorkspacesReturnsServerData() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        let primary = WorkspaceReference(
            uri: .threadWorkspace(timelineId),
            location: .runtime,
            rootPath: "/tmp/primary"
        )
        let attached = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/Users/dev/project"),
            location: .attached,
            rootPath: "/Users/dev/project"
        )
        await transport.seedTimelineWorkspaces(timelineId: timelineId, primary: primary, attached: [attached])
        let backend = MonadYakamozBackend(transport: transport)

        let result = try await backend.listTimelineWorkspaces(timelineId: timelineId)
        #expect(result.primary?.id == primary.id)
        #expect(result.attached.count == 1)
        #expect(result.attached.first?.id == attached.id)
    }

    @Test("listTimelineWorkspaces returns empty attached list for a timeline with no attached workspaces")
    func listTimelineWorkspacesEmpty() async throws {
        let transport = FakeTransport()
        let backend = MonadYakamozBackend(transport: transport)

        let result = try await backend.listTimelineWorkspaces(timelineId: UUID())
        #expect(result.primary == nil)
        #expect(result.attached.isEmpty)
    }

    @Test("listTimelineWorkspaces maps a transport error to a typed MonadBackendHealthError")
    func listTimelineWorkspacesMapsError() async throws {
        let transport = FakeTransport()
        await transport.setTimelineWorkspacesResult { _ in
            .failure(MonadClientError.notFound)
        }
        let backend = MonadYakamozBackend(transport: transport)

        await #expect(throws: MonadBackendHealthError.self) {
            _ = try await backend.listTimelineWorkspaces(timelineId: UUID())
        }
    }

    @Test("attach then detach round-trips through the transport's timeline workspace state")
    func attachDetachRoundTrip() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/Users/dev/project"),
            location: .attached,
            rootPath: "/Users/dev/project"
        )
        await transport.seedWorkspace(workspace)
        let backend = MonadYakamozBackend(transport: transport)

        try await backend.attachWorkspace(workspace.id, toTimeline: timelineId)

        let afterAttach = try await backend.listTimelineWorkspaces(timelineId: timelineId)
        #expect(afterAttach.attached.count == 1)
        #expect(afterAttach.attached.first?.id == workspace.id)

        try await backend.detachWorkspace(workspace.id, fromTimeline: timelineId)

        let afterDetach = try await backend.listTimelineWorkspaces(timelineId: timelineId)
        #expect(afterDetach.attached.isEmpty)
    }

    @Test("inspectorAvailable is true for Monad-backed turns (limited inspector, YAK-MON-8)")
    func inspectorAvailableTrue() {
        let transport = FakeTransport()
        let backend = MonadYakamozBackend(transport: transport)
        #expect(backend.inspectorAvailable)
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

    func setExecuteResult(_ result: Result<[TurnEvent], Error>) {
        executeResult = result
    }

    func setAgentInstancesResult(_ result: Result<[AgentInstance], Error>) {
        agentInstancesResult = result
    }

    func setAgentTemplatesResult(_ result: Result<[AgentTemplate], Error>) {
        agentTemplatesResult = result
    }

    func setAgentTimelinesResult(_ result: Result<[TimelineResponse], Error>) {
        agentTimelinesResult = result
    }

    // MARK: - YAK-MON-6: workspace helpers

    func seedWorkspace(_ workspace: WorkspaceReference) {
        allWorkspaces.append(workspace)
    }

    func seedTimelineWorkspaces(timelineId: UUID, primary: WorkspaceReference?, attached: [WorkspaceReference]) {
        timelineWorkspaces[timelineId] = (primary: primary, attached: attached)
    }

    func setWorkspacesResult(_ result: Result<[WorkspaceReference], Error>) {
        workspacesResult = result
    }

    func setTimelineWorkspacesResult(_ factory: @escaping (UUID) -> Result<(primary: WorkspaceReference?, attached: [WorkspaceReference]), Error>) {
        timelineWorkspacesResult = factory
    }

    func setAttachError(_ error: Error?) {
        attachError = error
    }

    func setDetachError(_ error: Error?) {
        detachError = error
    }
}
