import Foundation
import PKShared
import PositronicKit

/// A `WorkspaceProtocol` implementation confined to a single root directory on disk.
///
/// All file operations (`readFile`/`writeFile`/`listFiles`/`deleteFile`) and every
/// routed tool (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`, the same
/// six PKShared filesystem tools used elsewhere in PositronicKit) are confined to
/// `rootURL`. Confinement is enforced twice, independently:
///
/// 1. `confinedURL(for:)` below, used by the four direct file operations.
/// 2. Each PKShared filesystem tool's own `jailRoot`/`PathSanitizer.safelyResolve`
///    confinement, used when a tool id is routed through `executeTool`.
///
/// Both paths standardize and resolve symlinks for the candidate *and* the root before
/// comparing, so a symlink created inside the root that points outside of it cannot be
/// used to escape the sandbox (resolving the candidate turns it into its real,
/// out-of-root destination, which then fails the prefix check).
public actor FileSystemWorkspace: WorkspaceProtocol {
    public let id: UUID
    public let rootURL: URL
    private let displayName: String

    public init(id: UUID = UUID(), rootURL: URL, displayName: String? = nil) {
        self.id = id
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
    }

    public nonisolated var reference: WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: .requestOriginProject(hostname: "yakamoz", path: rootURL.path),
            location: .attached,
            tools: Self.toolIds.map { .known(id: $0) },
            rootPath: rootURL.path,
            trustLevel: .full
        )
    }

    // MARK: - WorkspaceProtocol: file operations

    public func readFile(path: String) async throws -> String {
        let url = try confinedURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkspaceError.workspaceNotFound
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw WorkspaceError.connectionFailed
        }
    }

    public func writeFile(path: String, content: String) async throws {
        let url = try confinedURL(for: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WorkspaceError.connectionFailed
        }
    }

    public func listFiles(path: String) async throws -> [String] {
        let url = try confinedURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.workspaceNotFound
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return contents.map(\.lastPathComponent).sorted()
        } catch {
            throw WorkspaceError.connectionFailed
        }
    }

    public func deleteFile(path: String) async throws {
        let url = try confinedURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceError.workspaceNotFound
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WorkspaceError.connectionFailed
        }
    }

    public func healthCheck() async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - WorkspaceProtocol: tool routing

    /// The PKShared filesystem tool ids this workspace exposes, in display order.
    static let toolIds = ["cat", "ls", "find", "search_files", "grep", "change_directory"]

    public func listTools() async throws -> [ToolReference] {
        Self.toolIds.map { .known(id: $0) }
    }

    public func executeTool(id toolId: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        let rawParameters = parameters.toAnyDictionary
        let tool: any Tool
        let root = rootURL.path
        switch toolId {
        case "cat":
            tool = ReadFileTool(currentDirectory: root, jailRoot: root)
        case "ls":
            tool = ListDirectoryTool(currentDirectory: root, jailRoot: root)
        case "find":
            tool = FindFileTool(currentDirectory: root, jailRoot: root)
        case "search_files":
            tool = SearchFilesTool(currentDirectory: root, jailRoot: root)
        case "grep":
            tool = SearchFileContentTool(currentDirectory: root, jailRoot: root)
        case "change_directory":
            tool = ChangeDirectoryTool(currentPath: rootURL.path) { _ in
                // No persistent "current directory" state on this workspace: every
                // tool call is jailed to `rootURL` independently, so changing
                // directory within the same root is a no-op beyond validating the
                // target path exists and is a directory (which the tool itself does).
            }
        default:
            throw WorkspaceError.toolExecutionNotSupported
        }

        return try await tool.execute(parameters: rawParameters)
    }

    // MARK: - Confinement

    /// Resolves `path` (relative or absolute) against `rootURL`, standardizing and
    /// resolving symlinks on both the root and the candidate before requiring the
    /// candidate to be the root itself or a path strictly beneath it. Throws
    /// `WorkspaceError.accessDenied` for any path — relative traversal, an absolute
    /// path elsewhere on disk, or a symlink whose real destination — that resolves
    /// outside the root.
    private func confinedURL(for path: String) throws -> URL {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()

        let unresolvedCandidate: URL = if path.hasPrefix("/") {
            URL(fileURLWithPath: path)
        } else {
            root.appendingPathComponent(path)
        }

        let candidate = unresolvedCandidate.standardizedFileURL.resolvingSymlinksInPath()

        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.accessDenied
        }

        return candidate
    }
}
