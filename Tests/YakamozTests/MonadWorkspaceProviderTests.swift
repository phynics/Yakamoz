import Foundation
import MonadClient
import MonadShared
import PKContracts
import Testing
@testable import YakamozCore

/// YAK-MON-5: exercises `MonadWorkspaceProvider` against fully in-memory fakes for both
/// the registration transport (`MonadWorkspaceRegistrationTransport`) and the RPC
/// connection (`MonadWorkspaceRPCConnection`) — no `URLSession`, no real `MonadClient`, no
/// live WebSocket, per the ticket's explicit requirement.
@Suite("MonadWorkspaceProvider")
struct MonadWorkspaceProviderTests {
    fileprivate actor FakeRegistrationTransport: MonadWorkspaceRegistrationTransport {
        var registeredTools: [ToolReference] = []
        var createdWorkspace: WorkspaceReference?
        var syncedTools: [ToolReference] = []
        var syncedWorkspaceId: UUID?
        let originId = UUID()

        func registerClient(
            hostname: String,
            displayName: String,
            platform: String,
            tools: [ToolReference]
        ) async throws -> ClientRegistrationResponse {
            registeredTools = tools
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
                originID: originId,
                tools: tools,
                rootPath: rootPath,
                trustLevel: trustLevel
            )
            createdWorkspace = workspace
            return workspace
        }

        func syncWorkspaceTools(_ tools: [ToolReference], workspaceId: UUID) async throws {
            syncedTools = tools
            syncedWorkspaceId = workspaceId
        }
    }

    /// Not an actor: `MonadWorkspaceRPCConnection.incomingRequests()` is a synchronous
    /// (non-`async`) requirement, so an actor conformance would need every witness
    /// `nonisolated`, which can't mutate actor state. Single-threaded test usage makes the
    /// `@unchecked Sendable` escape hatch safe here.
    fileprivate final class FakeRPCConnection: MonadWorkspaceRPCConnection, @unchecked Sendable {
        var connectedClientId: UUID?
        var sentResponses: [WorkspaceRPCResponseEnvelope] = []
        private var continuation: AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error>.Continuation?
        var disconnected = false

        func connect(clientId: UUID) async throws {
            connectedClientId = clientId
        }

        func incomingRequests() -> AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error> {
            AsyncThrowingStream { continuation in
                self.continuation = continuation
            }
        }

        func send(response: WorkspaceRPCResponseEnvelope) async throws {
            sentResponses.append(response)
        }

        func disconnect() async {
            disconnected = true
            continuation?.finish()
        }

        func push(_ request: WorkspaceRPCRequestEnvelope) {
            continuation?.yield(request)
        }
    }

    private func makeFolder() throws -> (FileSystemWorkspace, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("greeting.txt"), atomically: true, encoding: .utf8)
        return (FileSystemWorkspace(rootURL: root), root)
    }

    @Test("start registers a client, an attached workspace, and syncs tools")
    func startRegistersWorkspace() async throws {
        let (folder, root) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )

        let workspace = try await provider.start(folder: folder)

        #expect(workspace.location == .attached)
        #expect(workspace.rootPath == root.path)
        let createdWorkspace = await registrationTransport.createdWorkspace
        #expect(createdWorkspace?.id == workspace.id)
        let syncedWorkspaceId = await registrationTransport.syncedWorkspaceId
        #expect(syncedWorkspaceId == workspace.id)
        let connectedClientId = rpcConnection.connectedClientId
        #expect(connectedClientId != nil)
        let currentWorkspace = await provider.currentWorkspace
        #expect(currentWorkspace?.id == workspace.id)
    }

    @Test("handle readFile returns file contents via the jailed FileSystemWorkspace")
    func handleReadFile() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let params = try AnyCodable.from(["path": "greeting.txt"])
        let request = WorkspaceRPCRequestEnvelope(id: "1", method: "workspace/readFile", params: params)
        let response = await provider.handle(request: request)

        #expect(response.id == "1")
        #expect(response.error == nil)
        let content = try #require(response.result?.value as? String)
        #expect(content == "hello")
    }

    @Test("handle readFile rejects paths outside the workspace root")
    func handleReadFileRejectsEscape() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let params = try AnyCodable.from(["path": "../../etc/passwd"])
        let request = WorkspaceRPCRequestEnvelope(id: "2", method: "workspace/readFile", params: params)
        let response = await provider.handle(request: request)

        #expect(response.error != nil)
    }

    @Test("handle writeFile then listFiles round-trips through the jailed workspace")
    func handleWriteThenList() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let writeParams = try AnyCodable.from(["path": "notes.txt", "content": "written via rpc"])
        let writeRequest = WorkspaceRPCRequestEnvelope(id: "3", method: "workspace/writeFile", params: writeParams)
        let writeResponse = await provider.handle(request: writeRequest)
        #expect(writeResponse.error == nil)

        let listParams = try AnyCodable.from(["path": "."])
        let listRequest = WorkspaceRPCRequestEnvelope(id: "4", method: "workspace/listFiles", params: listParams)
        let listResponse = await provider.handle(request: listRequest)
        let files = try #require(listResponse.result?.value as? [Any])
        let names = files.compactMap { $0 as? String }
        #expect(names.contains("notes.txt"))
    }

    @Test("handle deleteFile removes the file from disk")
    func handleDeleteFile() async throws {
        let (folder, root) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let params = try AnyCodable.from(["path": "greeting.txt"])
        let request = WorkspaceRPCRequestEnvelope(id: "5", method: "workspace/deleteFile", params: params)
        let response = await provider.handle(request: request)

        #expect(response.error == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("greeting.txt").path))
    }

    @Test("handle executeTool routes through the jailed tool and reports failure results")
    func handleExecuteTool() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let params = try AnyCodable.from(["toolId": "cat", "parameters": ["path": "greeting.txt"]])
        let request = WorkspaceRPCRequestEnvelope(id: "6", method: "workspace/executeTool", params: params)
        let response = await provider.handle(request: request)

        #expect(response.error == nil)
    }

    @Test("handle rejects an unsupported RPC method")
    func handleUnsupportedMethod() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        let request = WorkspaceRPCRequestEnvelope(id: "7", method: "workspace/spawnTerminal", params: nil)
        let response = await provider.handle(request: request)

        #expect(response.error != nil)
    }

    @Test("handle before start reports no workspace registered")
    func handleBeforeStart() async {
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )

        let request = WorkspaceRPCRequestEnvelope(id: "8", method: "workspace/listFiles", params: nil)
        let response = await provider.handle(request: request)

        #expect(response.error != nil)
    }

    @Test("stop disconnects the RPC connection")
    func stopDisconnects() async throws {
        let (folder, _) = try makeFolder()
        let registrationTransport = FakeRegistrationTransport()
        let rpcConnection = FakeRPCConnection()
        let provider = MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: { rpcConnection }
        )
        _ = try await provider.start(folder: folder)

        await provider.stop()

        let disconnected = rpcConnection.disconnected
        #expect(disconnected)
        let currentWorkspace = await provider.currentWorkspace
        #expect(currentWorkspace == nil)
    }
}

private extension AnyCodable {
    static func from(_ dictionary: [String: Any]) throws -> AnyCodable {
        AnyCodable(dictionary)
    }
}
