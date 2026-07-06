import Foundation

/// Describes one attached folder workspace for which `YakamozRuntime.resolveTools` should
/// construct the filesystem tools (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`,
/// jailed to `rootURL`). `workspaceID` is the persisted `WorkspaceModel.id` so the folder's
/// `ToolProvenance.workspace(id:name:)` stays stable across tool refreshes — mirroring
/// `TerminalToolContext.workspaceId` for terminal workspaces (PKPOST-004c: provenance is
/// structural/stable by construction, not minted per `resolveTools` call).
public struct FolderToolContext: Sendable, Equatable {
    public let workspaceID: UUID
    public let rootURL: URL

    public init(workspaceID: UUID, rootURL: URL) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL
    }
}
