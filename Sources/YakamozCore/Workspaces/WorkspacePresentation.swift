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
/// health, a recursive file tree, and the workspace tool names it exposes.
///
/// This is conversation-level data (a workspace is attached to a conversation, not to a
/// specific turn), which is why `WorkspaceInspectorView` sources it independently of the
/// turn-scoped `InspectionPresentation` the other inspector tabs use (see Gap 2 in the
/// CP9 task notes).
public struct WorkspacePresentation: Sendable, Equatable {
    public let displayName: String
    public let folderPath: String
    public let isHealthy: Bool
    public let fileTree: [WorkspaceFileNode]
    public let toolNames: [String]

    public init(
        displayName: String,
        folderPath: String,
        isHealthy: Bool,
        fileTree: [WorkspaceFileNode],
        toolNames: [String]
    ) {
        self.displayName = displayName
        self.folderPath = folderPath
        self.isHealthy = isHealthy
        self.fileTree = fileTree
        self.toolNames = toolNames
    }

    /// Builds a presentation from a live `FileSystemWorkspace`, walking its root
    /// directory (capped depth/breadth to keep the inspector responsive on large
    /// folders) to produce `fileTree`.
    public static func build(from workspace: FileSystemWorkspace, displayName: String) async -> WorkspacePresentation {
        let isHealthy = await workspace.healthCheck()
        let rootURL = workspace.rootURL
        let tree = Self.buildTree(at: rootURL, relativeTo: rootURL, depth: 0)
        let toolNames = (try? await workspace.listTools().map(\.toolId)) ?? []

        return WorkspacePresentation(
            displayName: displayName,
            folderPath: rootURL.path,
            isHealthy: isHealthy,
            fileTree: tree,
            toolNames: toolNames
        )
    }

    /// Recursively walks `url`, capping depth at 6 levels and breadth at 200 entries per
    /// directory so a very large or deeply-nested folder cannot make the inspector hang.
    private static func buildTree(at url: URL, relativeTo root: URL, depth: Int) -> [WorkspaceFileNode] {
        guard depth < 6 else { return [] }
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let limited = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(200)

        return limited.map { childURL in
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = childURL.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let children = isDirectory ? buildTree(at: childURL, relativeTo: root, depth: depth + 1) : []
            return WorkspaceFileNode(
                id: relativePath,
                name: childURL.lastPathComponent,
                relativePath: relativePath,
                isDirectory: isDirectory,
                children: children
            )
        }
    }
}
