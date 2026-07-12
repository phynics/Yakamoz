import Foundation
import MonadClient
import MonadShared
import PKShared

/// YAK-MON-5: makes Yakamoz act as a Monad **attached-workspace provider** for folder
/// workspaces — the client-side counterpart to Monad server's `RemoteWorkspace`.
///
/// `MonadWorkspaceProvider` (1) registers Yakamoz as a Monad request origin/client, (2)
/// registers one Yakamoz folder workspace as a Monad `.attached` workspace and syncs its
/// tool set, (3) maintains a WebSocket RPC connection while Monad mode needs a workspace
/// provider, and (4) dispatches incoming `workspace/executeTool`/`readFile`/`writeFile`/
/// `deleteFile`/`listFiles` RPC calls to the **same jailed `FileSystemWorkspace`** Yakamoz
/// already uses for local folder workspaces — no parallel/unjailed file-access path is
/// introduced by this bridge. Path confinement and read-only-tool auto-approval therefore
/// come for free from `FileSystemWorkspace`/`ReadOnlyToolApproval`, not from new logic
/// here.
///
/// ## What's fully wired vs. seam-only (read before relying on this in production)
///
/// - **Fully wired, real Monad HTTP APIs**: client/request-origin registration
///   (`POST /api/clients/register`), attached-workspace creation (`POST /api/workspaces`
///   with `location: .attached`), and tool sync (`PUT /api/workspaces/{id}/tools`). These
///   go through `MonadWorkspaceRegistrationTransport`, whose live implementation wraps a
///   real `MonadClient` and hits real, already-shipped Monad server routes.
/// - **Seam-only, pending real transport**: the WebSocket push channel itself
///   (`workspace/executeTool` etc. arriving as server-initiated calls). The wire format is
///   concretely defined server-side (`RemoteWorkspace.swift`, `WorkspaceRPC.swift`,
///   `WebSocketAPIController.swift`) and `LiveMonadWorkspaceRPCConnection` implements the
///   documented client half of it, but:
///     1. `WebSocketAPIController`'s current read loop only decodes inbound frames as
///        `RPCResponse` — i.e. today the server does not yet read `RPCRequest` frames
///        *from* a client, only `RPCResponse` frames replying to something the server
///        sent. A live end-to-end round trip has not been (and cannot yet be) verified.
///     2. The wire contract has no workspace id in `workspace/*` request params —
///        `RemoteWorkspace` addresses a client purely by `clientId`. This provider
///        therefore supports exactly **one** registered folder workspace per connection;
///        multiplexing several simultaneously-attached folders for one Yakamoz instance
///        is not resolvable against the current protocol and is out of scope here.
///   `handle(request:)` — the dispatch logic that decodes an RPC request, executes it
///   against `FileSystemWorkspace`, and encodes the response — is fully implemented and
///   tested directly (bypassing `LiveMonadWorkspaceRPCConnection`/`URLSessionWebSocketTask`
///   entirely), per the ticket's requirement that automated tests use fakes/mocks for
///   server RPC.
/// - **Explicitly deferred**: terminal workspaces. `start(folder:)` only accepts folder
///   workspaces; there is no terminal equivalent. Any RPC method outside the five
///   `workspace/*` file methods above is rejected with
///   `MonadWorkspaceProviderError.unsupportedMethod`.
///
/// ## Manual smoke checklist (run against a real local `monad server`)
///
/// Automated tests cover `handle(request:)`'s dispatch/jailing/error-mapping logic with
/// fakes only (per the ticket's "no live network, no live WebSocket" requirement) — they
/// cannot prove the WebSocket round trip end to end, since (per above) the server doesn't
/// yet read `RPCRequest` frames from a client. Once that server-side gap is closed, verify
/// by hand:
///
/// 1. `cd Monad && swift run monad server` to start a local server.
/// 2. In Yakamoz, construct a `MonadWorkspaceProvider` for the active `MonadProfile` and a
///    `FileSystemWorkspace` rooted at some local folder, then call `start(folder:)`.
/// 3. Confirm `registerClient` succeeds — `GET /api/clients` on the server should list a
///    Yakamoz origin.
/// 4. Confirm the attached workspace was created — `GET /api/workspaces` should list one
///    `.attached` workspace with `originId` matching the registered client and `rootPath`
///    matching the local folder.
/// 5. From another Monad client (e.g. `monad chat`), attach that workspace to a timeline
///    and ask the agent to list files in it — expect the request to reach this provider's
///    `handle(request:)` for `workspace/listFiles` and return real directory contents.
/// 6. Ask the agent to read a known file in the folder — expect the real file contents
///    back via `workspace/readFile`.
/// 7. Ask the agent to write/create a file — expect it to appear on disk under the folder,
///    routed via `workspace/writeFile`.
/// 8. Attempt (via a crafted/forced RPC or a follow-up ticket's test harness) a path
///    outside the folder root (e.g. `../../etc/passwd`) — expect `accessDenied`, not a
///    successful read, proving jailing survived the RPC hop.
/// 9. Stop `monad server` mid-session — expect `LiveMonadWorkspaceRPCConnection`'s
///    `incomingRequests()` stream to finish (with an error), not hang.
public actor MonadWorkspaceProvider {
    private let registrationTransport: any MonadWorkspaceRegistrationTransport
    private let connectionFactory: @Sendable () -> any MonadWorkspaceRPCConnection
    private let hostname: String
    private let displayName: String
    private let platform: String

    private var connection: (any MonadWorkspaceRPCConnection)?
    private var pumpTask: Task<Void, Never>?
    private var registeredClientId: UUID?
    private var registeredWorkspace: WorkspaceReference?
    private var folderWorkspace: FileSystemWorkspace?

    public init(
        registrationTransport: any MonadWorkspaceRegistrationTransport,
        connectionFactory: @escaping @Sendable () -> any MonadWorkspaceRPCConnection,
        hostname: String = ProcessInfo.processInfo.hostName,
        displayName: String = "Yakamoz",
        platform: String = "macos"
    ) {
        self.registrationTransport = registrationTransport
        self.connectionFactory = connectionFactory
        self.hostname = hostname
        self.displayName = displayName
        self.platform = platform
    }

    /// Currently-registered attached workspace, if `start(folder:)` has completed.
    public var currentWorkspace: WorkspaceReference? {
        registeredWorkspace
    }

    /// Registers Yakamoz as a Monad client, registers `folder` as an `.attached`
    /// workspace, syncs its tool set, and opens the RPC connection so incoming
    /// `workspace/*` requests are served against `folder`.
    ///
    /// Only one folder workspace may be active per provider instance — see the type doc
    /// comment's "contract gap" note on why the wire protocol cannot disambiguate multiple
    /// attached workspaces for a single client today.
    @discardableResult
    public func start(folder: FileSystemWorkspace) async throws -> WorkspaceReference {
        await stop()

        let tools = try await folder.listTools()

        let registration = try await registrationTransport.registerClient(
            hostname: hostname,
            displayName: displayName,
            platform: platform,
            tools: tools
        )
        let clientId = registration.origin.id
        registeredClientId = clientId

        let workspace = try await registrationTransport.createAttachedWorkspace(
            uri: await folder.reference.uri,
            originId: clientId,
            rootPath: await folder.reference.rootPath ?? "",
            trustLevel: await folder.reference.trustLevel,
            tools: tools
        )
        try await registrationTransport.syncWorkspaceTools(tools, workspaceId: workspace.id)
        registeredWorkspace = workspace
        folderWorkspace = folder

        let connection = connectionFactory()
        try await connection.connect(clientId: clientId)
        self.connection = connection

        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await request in connection.incomingRequests() {
                    await self.dispatch(request, over: connection)
                }
            } catch {
                // Stream ended (closed connection or transport error). `stop()`/a future
                // `start(folder:)` call is the caller's reconnection path.
            }
        }

        return workspace
    }

    /// Closes the RPC connection and clears provider state. Idempotent.
    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        await connection?.disconnect()
        connection = nil
        registeredClientId = nil
        registeredWorkspace = nil
        folderWorkspace = nil
    }

    private func dispatch(
        _ request: WorkspaceRPCRequestEnvelope,
        over connection: any MonadWorkspaceRPCConnection
    ) async {
        let response = await handle(request: request)
        try? await connection.send(response: response)
    }

    /// Decodes `request`, executes it against the active `FileSystemWorkspace`, and
    /// returns the RPC response to send back. Exposed `internal` (not `private`) so tests
    /// can drive it directly without a real/fake `MonadWorkspaceRPCConnection`, per the
    /// ticket's fakes/mocks-only requirement for RPC behavior.
    func handle(request: WorkspaceRPCRequestEnvelope) async -> WorkspaceRPCResponseEnvelope {
        guard let folderWorkspace else {
            return WorkspaceRPCResponseEnvelope(id: request.id, error: MonadWorkspaceProviderError.unknownWorkspace.localizedDescription)
        }
        guard let method = WorkspaceRPCMethod(rawValue: request.method) else {
            return WorkspaceRPCResponseEnvelope(
                id: request.id,
                error: MonadWorkspaceProviderError.unsupportedMethod(request.method).localizedDescription
            )
        }

        do {
            switch method {
            case .executeTool:
                let params: WorkspaceRPCToolExecutionRequest = try decode(request.params)
                let result = try await folderWorkspace.executeTool(id: params.toolId, parameters: params.parameters)
                let toolResponse: WorkspaceRPCToolExecutionResponse = result.success
                    ? .success(output: result.output)
                    : .failure(result.error ?? "Unknown error")
                return try encode(id: request.id, value: toolResponse)

            case .readFile:
                let params: WorkspaceRPCReadFileRequest = try decode(request.params)
                let content = try await folderWorkspace.readFile(path: params.path)
                return try encode(id: request.id, value: content)

            case .writeFile:
                let params: WorkspaceRPCWriteFileRequest = try decode(request.params)
                try await folderWorkspace.writeFile(path: params.path, content: params.content)
                return try encode(id: request.id, value: true)

            case .deleteFile:
                let params: WorkspaceRPCDeleteFileRequest = try decode(request.params)
                try await folderWorkspace.deleteFile(path: params.path)
                return try encode(id: request.id, value: true)

            case .listFiles:
                let params: WorkspaceRPCListFilesRequest = try decode(request.params)
                let files = try await folderWorkspace.listFiles(path: params.path)
                return try encode(id: request.id, value: files)
            }
        } catch {
            return WorkspaceRPCResponseEnvelope(id: request.id, error: String(describing: error))
        }
    }

    private func decode<T: Decodable>(_ params: AnyCodable?) throws -> T {
        guard let params else {
            throw MonadWorkspaceProviderError.unsupportedMethod("missing params")
        }
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encode(id: String, value: some Encodable) throws -> WorkspaceRPCResponseEnvelope {
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return WorkspaceRPCResponseEnvelope(id: id, result: AnyCodable(json))
    }
}

extension MonadWorkspaceProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Invalid Monad server URL."
        case .notConnected: "Not connected to the Monad server."
        case let .unsupportedMethod(method): "Unsupported RPC method: \(method)."
        case .terminalWorkspacesUnavailable: "Terminal workspaces are not available in Monad mode."
        case .unknownWorkspace: "No folder workspace is registered with this provider."
        }
    }
}
