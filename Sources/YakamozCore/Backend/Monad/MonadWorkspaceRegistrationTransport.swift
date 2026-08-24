import Foundation
import MonadClient
import MonadShared
import PKContracts

/// The narrow slice of `MonadClient` that `MonadWorkspaceProvider` needs to register
/// itself as a Monad request origin and register/sync Yakamoz-owned attached workspaces.
///
/// These are ordinary REST calls that already exist on `MonadClient`
/// (`MonadClient+Clients.swift`, `MonadClient+Workspaces.swift`) — they are not the part
/// of this ticket that's outrunning the server. The push RPC channel (server → client
/// tool/file execution) is the part that only has a wire format defined server-side
/// (`Monad/Sources/MonadServer/Models/Workspace/RemoteWorkspace.swift` and
/// `WorkspaceRPC.swift`) with no client-side implementation anywhere yet; see
/// `MonadWorkspaceRPCConnection` for that seam.
public protocol MonadWorkspaceRegistrationTransport: Sendable {
    /// Registers Yakamoz as a Monad request origin ("client" in Monad's REST vocabulary),
    /// advertising the folder-workspace tool ids it can serve. Returns the origin identity
    /// Monad assigned, whose `id` is the `originId`/`clientId` used for every subsequent
    /// workspace-registration and RPC call.
    func registerClient(
        hostname: String,
        displayName: String,
        platform: String,
        tools: [ToolReference]
    ) async throws -> ClientRegistrationResponse

    /// Registers one Yakamoz folder workspace as a Monad `.attached` workspace owned by
    /// `originId`.
    func createAttachedWorkspace(
        uri: WorkspaceURI,
        originId: UUID,
        rootPath: String,
        trustLevel: WorkspaceTrustLevel,
        tools: [ToolReference]
    ) async throws -> WorkspaceReference

    /// Atomically replaces the tool set Monad has on file for `workspaceId` with `tools`.
    /// Providers are expected to call this on every connect/reconnect.
    func syncWorkspaceTools(_ tools: [ToolReference], workspaceId: UUID) async throws
}

/// Live `MonadWorkspaceRegistrationTransport` wrapping a real `MonadClient`.
public struct LiveMonadWorkspaceRegistrationTransport: MonadWorkspaceRegistrationTransport {
    private let client: MonadClient

    public init(client: MonadClient) {
        self.client = client
    }

    public func registerClient(
        hostname: String,
        displayName: String,
        platform: String,
        tools: [ToolReference]
    ) async throws -> ClientRegistrationResponse {
        try await client.registerClient(
            hostname: hostname,
            displayName: displayName,
            platform: platform,
            tools: tools
        )
    }

    public func createAttachedWorkspace(
        uri: WorkspaceURI,
        originId: UUID,
        rootPath: String,
        trustLevel: WorkspaceTrustLevel,
        tools: [ToolReference]
    ) async throws -> WorkspaceReference {
        try await client.workspace.createWorkspace(
            uri: uri,
            location: .attached,
            originId: originId,
            rootPath: rootPath,
            trustLevel: trustLevel,
            tools: tools
        )
    }

    public func syncWorkspaceTools(_ tools: [ToolReference], workspaceId: UUID) async throws {
        try await client.workspace.syncWorkspaceTools(tools, workspaceId: workspaceId)
    }
}
