import Foundation
import PKShared

/// App-target-safe projection of a Monad server `WorkspaceReference`, suitable for the
/// `Yakamoz` app target to bind to without importing `PKShared` directly (per the
/// app-target import boundary).
///
/// Carries enough identity/status/kind data for the Monad-mode workspace attachment UI to
/// render chips, show detach buttons, and mark terminal workspaces as unavailable — the
/// one Monad-specific concept the generic `BackendWorkspaceSummary` intentionally drops.
public struct MonadWorkspacePresentation: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folder
        case terminal
    }

    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(String)
    }

    public let id: UUID
    public let displayName: String
    public let rootPath: String?
    public let kind: Kind
    public let availability: Availability

    public init(id: UUID, displayName: String, rootPath: String?, kind: Kind, availability: Availability) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.kind = kind
        self.availability = availability
    }

    public init(workspace: WorkspaceReference) {
        id = workspace.id
        rootPath = workspace.rootPath
        let isTerminal = workspace.uri.host == "pk-terminal"
        kind = isTerminal ? .terminal : .folder

        if let rootPath = workspace.rootPath, !rootPath.isEmpty {
            displayName = (rootPath as NSString).lastPathComponent
        } else {
            let pathComponent = (workspace.uri.path as NSString).lastPathComponent
            displayName = pathComponent.isEmpty ? workspace.uri.description : pathComponent
        }

        switch workspace.status {
        case .active:
            availability = isTerminal
                ? .unavailable("Terminal workspaces are not available in Monad mode.")
                : .available
        case .missing:
            availability = .unavailable("Workspace location not found.")
        case .unknown:
            availability = .unavailable("Workspace status is unknown.")
        }
    }
}
