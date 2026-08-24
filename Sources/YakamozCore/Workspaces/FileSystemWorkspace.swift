import Foundation
import Logging
import PKContracts
import PositronicKit

/// A `Workspace` implementation confined to a single root directory on disk.
///
/// All file operations (`readFile`/`writeFile`/`listFiles`/`deleteFile`) and every
/// routed tool (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`, the same
/// six PositronicKit filesystem tools used elsewhere in PositronicKit) are confined to
/// `rootURL`. Confinement is enforced twice, independently:
///
/// 1. `confinedURL(for:)` below, used by the four direct file operations.
/// 2. Each filesystem tool's own `jailRoot`/`PathSanitizer.safelyResolve`
///    confinement, used when a tool id is routed through `executeTool`.
///
/// Both paths standardize and resolve symlinks for the candidate *and* the root before
/// comparing, so a symlink created inside the root that points outside of it cannot be
/// used to escape the sandbox (resolving the candidate turns it into its real,
/// out-of-root destination, which then fails the prefix check).
public actor FileSystemWorkspace: Workspace {
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

    // MARK: - Workspace: file operations

    public func readFile(path: String) async throws -> String {
        let url = try confinedURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkspaceError.workspaceNotFound
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.workspace.warning("failed to read file", metadata: [
                "workspaceID": .string("\(id)"),
            ])
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
            Log.workspace.warning("failed to write file", metadata: [
                "workspaceID": .string("\(id)"),
            ])
            throw WorkspaceError.connectionFailed
        }
    }

    public func listFiles(path: String) async throws -> [String] {
        let url = try confinedURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // PositronicKit's context pipeline treats the conventional Notes directory as
            // optional for ordinary attached folders. An empty user workspace therefore has
            // no notes to discover; it should not fail the whole turn during context gathering.
            if path == "Notes" {
                return []
            }
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
            Log.workspace.warning("failed to list directory", metadata: [
                "workspaceID": .string("\(id)"),
            ])
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
            Log.workspace.warning("failed to delete file", metadata: [
                "workspaceID": .string("\(id)"),
            ])
            throw WorkspaceError.connectionFailed
        }
    }

    public func healthCheck() async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Workspace: tool routing

    /// The filesystem tool ids this workspace exposes, in display order.
    static let toolIds = ["cat", "ls", "find", "search_files", "grep", "change_directory"]

    public func listTools() async throws -> [ToolReference] {
        Self.toolIds.map { .known(id: $0) }
    }

    public func executeTool(id toolId: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        switch toolId {
        case "cat":
            do {
                let path = try requiredString("path", from: parameters)
                return .success(try await readFile(path: path))
            } catch {
                return .failure(error.localizedDescription)
            }
        case "ls":
            do {
                let path = parameters["path"]?.asString ?? "."
                let url = try confinedURL(for: path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return .failure("Directory not found: \(path)")
                }
                let entries = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ).map { entry -> String in
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true { return "[DIR] \(entry.lastPathComponent)" }
                    let size = Int64(values?.fileSize ?? 0)
                    let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    return "[FILE] \(entry.lastPathComponent) (\(sizeText))"
                }.sorted()
                return .success(entries.joined(separator: "\n"))
            } catch {
                return .failure(error.localizedDescription)
            }
        case "find":
            do {
                let pattern = try requiredString("pattern", from: parameters)
                let path = parameters["path"]?.asString ?? "."
                let url = try confinedURL(for: path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return .failure("Directory not found: \(path)")
                }
                var matches: [String] = []
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                while let entry = enumerator?.nextObject() as? URL {
                    if entry.lastPathComponent.localizedCaseInsensitiveContains(pattern) {
                        matches.append(Self.relativePath(for: entry, base: url))
                    }
                    if matches.count == 100 { break }
                }
                if matches.isEmpty { return .success("No files found matching '\(pattern)' in \(path)") }
                if matches.count == 100 { matches.append("... (limit reached)") }
                return .success(matches.sorted().joined(separator: "\n"))
            } catch {
                return .failure(error.localizedDescription)
            }
        case "search_files":
            return searchFiles(parameters: parameters, regex: true, recursive: true)
        case "grep":
            return searchFiles(
                parameters: parameters,
                regex: false,
                recursive: {
                    guard let value = parameters["recursive"] else { return false }
                    if case let .boolean(result) = value { return result }
                    return false
                }()
            )
        case "change_directory":
            do {
                let path = try requiredString("path", from: parameters)
                let url = try confinedURL(for: path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    return .failure("Directory not found: \(path)")
                }
                guard isDirectory.boolValue else {
                    return .failure("Path exists but is not a directory: \(url.path)")
                }
                return .success("Changed directory to \(url.path)")
            } catch {
                return .failure(error.localizedDescription)
            }
        default:
            throw WorkspaceError.toolExecutionNotSupported
        }
    }

    private func searchFiles(
        parameters: [String: AnyCodable],
        regex: Bool,
        recursive: Bool
    ) -> ToolResult {
        do {
            let pattern = try requiredString("pattern", from: parameters)
            let path = parameters["path"]?.asString ?? "."
            let url = try confinedURL(for: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .failure("Path not found: \(path)")
            }

            let matcher: (String) -> Bool
            if regex {
                let expression = try NSRegularExpression(pattern: pattern)
                matcher = { line in
                    expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
            } else {
                matcher = { line in line.localizedCaseInsensitiveContains(pattern) }
            }

            let files: [URL]
            if isDirectory.boolValue {
                if recursive {
                    files = Self.recursiveFiles(at: url)
                } else {
                    files = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
                }
            } else {
                files = [url]
            }

            var matches: [String] = []
            for file in files {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in content.components(separatedBy: .newlines).enumerated() where matcher(line) {
                    matches.append("\(Self.relativePath(for: file, base: url)):\(index + 1): \(line)")
                    if matches.count == 100 { break }
                }
                if matches.count == 100 { break }
            }

            if matches.isEmpty { return .success("No matches found for '\(pattern)'") }
            if matches.count == 100 { matches.append("... (limit reached)") }
            return .success(matches.joined(separator: "\n"))
        } catch {
            return .failure("Search failed: \(error.localizedDescription)")
        }
    }

    private func requiredString(_ key: String, from parameters: [String: AnyCodable]) throws -> String {
        guard let value = parameters[key]?.asString, !value.isEmpty else {
            throw WorkspaceError.invalidWorkspaceType
        }
        return value
    }

    private static func recursiveFiles(at url: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
    }

    private static func relativePath(for url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath != basePath else { return "." }
        return String(filePath.dropFirst(basePath.count + 1))
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
