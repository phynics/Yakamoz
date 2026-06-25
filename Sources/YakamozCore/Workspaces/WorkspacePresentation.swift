import Foundation
import PositronicKit

/// A single node in a workspace's recursive file tree, as shown by `WorkspaceInspectorView`.
public struct WorkspaceFileNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool
    public let children: [WorkspaceFileNode]

    public init(id: String, name: String, relativePath: String, isDirectory: Bool, children: [WorkspaceFileNode]) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// A `Sendable`, app-target-safe projection of one `FileSystemWorkspace`: folder path,
/// health, and the workspace tool names it exposes.
///
/// This is conversation-level data (a workspace is attached to a conversation, not to a
/// specific turn), which is why `WorkspaceInspectorView` sources it independently of the
/// turn-scoped `InspectionPresentation` the other inspector tabs use (see Gap 2 in the
/// CP9 task notes).
///
/// **YAK-17:** this no longer enumerates the workspace's file tree — the Workspace tab
/// dropped the file-list UI, so `build` avoids the unnecessary directory walk. The
/// `WorkspaceFileNode` type is kept (still `Sendable`/`Equatable`) in case a future tab
/// wants a lightweight tree again, but nothing currently populates it.
public struct WorkspacePresentation: Sendable, Equatable {
    public let displayName: String
    public let folderPath: String
    public let isHealthy: Bool
    public let toolNames: [String]

    public init(
        displayName: String,
        folderPath: String,
        isHealthy: Bool,
        toolNames: [String]
    ) {
        self.displayName = displayName
        self.folderPath = folderPath
        self.isHealthy = isHealthy
        self.toolNames = toolNames
    }

    /// Builds a presentation from a live `FileSystemWorkspace`. Per YAK-17, this no longer
    /// walks the workspace's root directory — the Workspace tab shows identity/health/tools
    /// only, so the (potentially expensive) file enumeration is skipped entirely.
    public static func build(from workspace: FileSystemWorkspace, displayName: String) async -> WorkspacePresentation {
        let isHealthy = await workspace.healthCheck()
        let rootURL = workspace.rootURL
        let toolNames = (try? await workspace.listTools().map(\.toolId)) ?? []

        return WorkspacePresentation(
            displayName: displayName,
            folderPath: rootURL.path,
            isHealthy: isHealthy,
            toolNames: toolNames
        )
    }
}
