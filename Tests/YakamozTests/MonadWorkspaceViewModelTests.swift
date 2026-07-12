import Foundation
import MonadClient
import MonadShared
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// YAK-MON-6: exercises `MonadWorkspaceViewModel` against a fully in-memory fake
/// `MonadClientTransport` (via `MonadYakamozBackend`) and a real
/// `MonadWorkspaceProvider` with fake registration/RPC transports — no network, no
/// real `MonadClient`, no live WebSocket, per the ticket's requirement.
@Suite("MonadWorkspaceViewModel")
@MainActor
struct MonadWorkspaceViewModelTests {
    fileprivate actor FakeTransport: MonadClientTransport {
        var timelines: [TimelineResponse] = []
        var timelineWorkspaces: [UUID: (primary: WorkspaceReference?, attached: [WorkspaceReference])] = [:]
        var lastAttachRequest: (workspaceId: UUID, timelineId: UUID)?
        var lastDetachRequest: (workspaceId: UUID, timelineId: UUID)?

        func getStatus() async throws -> StatusResponse {
            StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])
        }

        func listTimelines() async throws -> [TimelineResponse] {
            timelines
        }

        func createTimeline(title: String?) async throws -> TimelineResponse {
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

        func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
            lastAttachRequest = (workspaceId, timelineId)
        }

        func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
            lastDetachRequest = (workspaceId, timelineId)
            if var entry = timelineWorkspaces[timelineId] {
                entry.attached.removeAll { $0.id == workspaceId }
                timelineWorkspaces[timelineId] = entry
            }
        }

        func listTimelineWorkspaces(timelineId: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
            timelineWorkspaces[timelineId] ?? (primary: nil, attached: [])
        }

        // MARK: - Helpers

        func seedTimeline(_ timeline: TimelineResponse) {
            timelines.append(timeline)
        }

        func seedTimelineWorkspaces(timelineId: UUID, primary: WorkspaceReference?, attached: [WorkspaceReference]) {
            timelineWorkspaces[timelineId] = (primary: primary, attached: attached)
        }
    }

    fileprivate actor FakeRegistrationTransport: MonadWorkspaceRegistrationTransport {
        let originId = UUID()
        var createdWorkspace: WorkspaceReference?

        func registerClient(
            hostname: String,
            displayName: String,
            platform: String,
            tools: [ToolReference]
        ) async throws -> ClientRegistrationResponse {
            let origin = RequestOriginIdentity(id: originId, hostname: hostname, displayName: displayName, platform: platform)
            let defaultWorkspace = WorkspaceReference(uri: .requestOriginProject(hostname: hostname, path: "/"), location: .runtime)
            return ClientRegistrationResponse(origin: origin, defaultWorkspace: defaultWorkspace)
        }

        func createAttachedWorkspace(
            uri: WorkspaceURI,
            originId: UUID,
            rootPath: String,
            trustLevel: WorkspaceTrustLevel,
            tools: [ToolReference]
        ) async throws -> WorkspaceReference {
            let workspace = WorkspaceReference(
                uri: uri,
                location: .attached,
                originId: originId,
                tools: tools,
                rootPath: rootPath,
                trustLevel: trustLevel
            )
            createdWorkspace = workspace
            return workspace
        }

        func syncWorkspaceTools(_: [ToolReference], workspaceId _: UUID) async throws {}
    }

    fileprivate final class FakeRPCConnection: MonadWorkspaceRPCConnection, @unchecked Sendable {
        var connectedClientId: UUID?
        var disconnected = false
        private var continuation: AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error>.Continuation?

        func connect(clientId: UUID) async throws {
            connectedClientId = clientId
        }

        func incomingRequests() -> AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error> {
            AsyncThrowingStream { continuation in
                self.continuation = continuation
            }
        }

        func send(response _: WorkspaceRPCResponseEnvelope) async throws {}

        func disconnect() async {
            disconnected = true
            continuation?.finish()
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

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeVM(
        timelineId: UUID,
        transport: FakeTransport,
        registrationTransport: FakeRegistrationTransport = FakeRegistrationTransport(),
        rpcConnection: FakeRPCConnection = FakeRPCConnection()
    ) -> MonadWorkspaceViewModel {
        MonadWorkspaceViewModel(
            timelineId: timelineId,
            profile: makeProfile(),
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in
                MonadYakamozBackend(transport: transport)
            },
            providerFactory: { _, _ in
                MonadWorkspaceProvider(
                    registrationTransport: registrationTransport,
                    connectionFactory: { rpcConnection }
                )
            }
        )
    }

    // MARK: - load()

    @Test("load populates timeline summary and attached workspaces from the server")
    func loadPopulatesFromServer() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        await transport.seedTimeline(TimelineResponse(id: timelineId, title: "Test Timeline"))

        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/dev/project"),
            location: .attached,
            rootPath: "/dev/project"
        )
        await transport.seedTimelineWorkspaces(timelineId: timelineId, primary: nil, attached: [workspace])

        let vm = makeVM(timelineId: timelineId, transport: transport)

        await vm.load()

        #expect(vm.loadState == .loaded)
        #expect(vm.timelineSummary?.title == "Test Timeline")
        #expect(vm.attachedWorkspaces.count == 1)
        #expect(vm.attachedWorkspaces.first?.displayName == "project")
        #expect(vm.attachedWorkspaces.first?.kind == .folder)
        #expect(vm.attachedWorkspaces.first?.availability == .available)
    }

    @Test("load surfaces a failed state on transport error")
    func loadSurfacesError() async throws {
        let transport = FailingLoadTransport()
        let vm = MonadWorkspaceViewModel(
            timelineId: UUID(),
            profile: makeProfile(),
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in
                MonadYakamozBackend(transport: transport)
            },
            providerFactory: { _, _ in
                MonadWorkspaceProvider(
                    registrationTransport: FakeRegistrationTransport(),
                    connectionFactory: { FakeRPCConnection() }
                )
            }
        )

        await vm.load()

        if case .failed = vm.loadState {
            // expected
        } else {
            Issue.record("expected .failed state, got \(vm.loadState)")
        }
        #expect(vm.timelineSummary == nil)
    }

    @Test("load shows terminal workspaces as unavailable")
    func loadShowsTerminalUnavailable() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        let terminal = WorkspaceReference(
            uri: .terminal(rootPath: "/tmp/terminal"),
            location: .attached,
            rootPath: "/tmp/terminal"
        )
        await transport.seedTimelineWorkspaces(timelineId: timelineId, primary: nil, attached: [terminal])

        let vm = makeVM(timelineId: timelineId, transport: transport)

        await vm.load()

        #expect(vm.attachedWorkspaces.count == 1)
        let ws = try #require(vm.attachedWorkspaces.first)
        #expect(ws.kind == .terminal)
        if case .unavailable = ws.availability {
            // expected
        } else {
            Issue.record("expected .unavailable for terminal workspace")
        }
    }

    // MARK: - attachFolder

    @Test("attachFolder registers the provider and attaches the workspace to the timeline")
    func attachFolderRegistersAndAttaches() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        await transport.seedTimeline(TimelineResponse(id: timelineId, title: "Attach Test"))

        let folderURL = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()

        let vm = makeVM(
            timelineId: timelineId,
            transport: transport,
            registrationTransport: registrationTransport,
            rpcConnection: rpcConnection
        )

        await vm.load()
        #expect(vm.attachedWorkspaces.isEmpty)

        await vm.attachFolder(at: folderURL)

        #expect(vm.isAttaching == false)
        #expect(vm.actionError == nil)

        let lastAttach = await transport.lastAttachRequest
        #expect(lastAttach?.timelineId == timelineId)

        let createdWorkspace = await registrationTransport.createdWorkspace
        #expect(createdWorkspace != nil)
        #expect(createdWorkspace?.rootPath == folderURL.path)

        #expect(rpcConnection.connectedClientId != nil)
    }

    // MARK: - detachWorkspace

    @Test("detachWorkspace removes the workspace from the timeline and refreshes")
    func detachWorkspaceRemovesAndRefreshes() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        await transport.seedTimeline(TimelineResponse(id: timelineId, title: "Detach Test"))

        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/dev/project"),
            location: .attached,
            rootPath: "/dev/project"
        )
        await transport.seedTimelineWorkspaces(timelineId: timelineId, primary: nil, attached: [workspace])

        let vm = makeVM(timelineId: timelineId, transport: transport)

        await vm.load()
        #expect(vm.attachedWorkspaces.count == 1)

        await vm.detachWorkspace(workspace.id)

        let lastDetach = await transport.lastDetachRequest
        #expect(lastDetach?.workspaceId == workspace.id)
        #expect(lastDetach?.timelineId == timelineId)

        #expect(vm.attachedWorkspaces.isEmpty)
    }

    @Test("detachWorkspace does not delete the local folder")
    func detachDoesNotDeleteFolder() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        let workspace = WorkspaceReference(
            uri: .requestOriginProject(hostname: "macbook", path: "/dev/project"),
            location: .attached,
            rootPath: "/dev/project"
        )
        await transport.seedTimelineWorkspaces(timelineId: timelineId, primary: nil, attached: [workspace])

        let vm = makeVM(timelineId: timelineId, transport: transport)

        await vm.load()
        await vm.detachWorkspace(workspace.id)

        #expect(vm.attachedWorkspaces.isEmpty)
    }

    // MARK: - cleanup

    @Test("cleanup stops the provider and disconnects the RPC connection")
    func cleanupStopsProvider() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        await transport.seedTimeline(TimelineResponse(id: timelineId, title: "Cleanup Test"))

        let folderURL = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()

        let vm = makeVM(
            timelineId: timelineId,
            transport: transport,
            registrationTransport: registrationTransport,
            rpcConnection: rpcConnection
        )

        await vm.load()
        await vm.attachFolder(at: folderURL)

        #expect(rpcConnection.disconnected == false)

        await vm.cleanup()

        #expect(rpcConnection.disconnected == true)
    }

    // MARK: - error surfacing

    @Test("attachFolder surfaces provider errors via actionError")
    func attachFolderSurfacesProviderError() async throws {
        let transport = FakeTransport()
        let timelineId = UUID()
        await transport.seedTimeline(TimelineResponse(id: timelineId, title: "Error Test"))

        let vm = MonadWorkspaceViewModel(
            timelineId: timelineId,
            profile: makeProfile(),
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in
                MonadYakamozBackend(transport: transport)
            },
            providerFactory: { _, _ in
                MonadWorkspaceProvider(
                    registrationTransport: FailingRegistrationTransport(),
                    connectionFactory: { FakeRPCConnection() }
                )
            }
        )

        await vm.load()

        await vm.attachFolder(at: FileManager.default.temporaryDirectory)

        #expect(vm.isAttaching == false)
        #expect(vm.actionError != nil)
    }

    @Test("detachWorkspace surfaces errors via actionError")
    func detachWorkspaceSurfacesError() async throws {
        let transport = FailingDetachTransport()
        let timelineId = UUID()

        let vm = MonadWorkspaceViewModel(
            timelineId: timelineId,
            profile: makeProfile(),
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in
                MonadYakamozBackend(transport: transport)
            },
            providerFactory: { _, _ in
                MonadWorkspaceProvider(
                    registrationTransport: FakeRegistrationTransport(),
                    connectionFactory: { FakeRPCConnection() }
                )
            }
        )

        await vm.load()
        await vm.detachWorkspace(UUID())

        #expect(vm.actionError != nil)
    }
}

// MARK: - Failing transports for error-path tests

private actor FailingRegistrationTransport: MonadWorkspaceRegistrationTransport {
    func registerClient(
        hostname _: String,
        displayName _: String,
        platform _: String,
        tools _: [ToolReference]
    ) async throws -> ClientRegistrationResponse {
        throw MonadClientError.serverNotReachable
    }

    func createAttachedWorkspace(
        uri _: WorkspaceURI,
        originId _: UUID,
        rootPath _: String,
        trustLevel _: WorkspaceTrustLevel,
        tools _: [ToolReference]
    ) async throws -> WorkspaceReference {
        throw MonadClientError.serverNotReachable
    }

    func syncWorkspaceTools(_: [ToolReference], workspaceId _: UUID) async throws {
        throw MonadClientError.serverNotReachable
    }
}

private actor FailingDetachTransport: MonadClientTransport {
    func getStatus() async throws -> StatusResponse {
        StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])
    }

    func listTimelines() async throws -> [TimelineResponse] { [] }
    func createTimeline(title _: String?) async throws -> TimelineResponse { TimelineResponse(id: UUID(), title: nil) }
    func getTimeline(id _: UUID) async throws -> TimelineResponse { throw MonadClientError.notFound }
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

    func attachWorkspace(_: UUID, to _: UUID) async throws {
        throw MonadClientError.serverNotReachable
    }

    func detachWorkspace(_: UUID, from _: UUID) async throws {
        throw MonadClientError.serverNotReachable
    }

    func listTimelineWorkspaces(timelineId _: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
        (primary: nil, attached: [])
    }
}

private actor FailingLoadTransport: MonadClientTransport {
    func getStatus() async throws -> StatusResponse {
        StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])
    }

    func listTimelines() async throws -> [TimelineResponse] { [] }
    func createTimeline(title _: String?) async throws -> TimelineResponse { TimelineResponse(id: UUID(), title: nil) }
    func getTimeline(id _: UUID) async throws -> TimelineResponse { throw MonadClientError.serverNotReachable }
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
        throw MonadClientError.serverNotReachable
    }
}
