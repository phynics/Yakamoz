import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("FileSystemWorkspace")
struct FileSystemWorkspaceTests {
    // MARK: - Fixtures

    /// Creates a fresh temp directory for the duration of one test, with `rootPath`
    /// already symlink-resolved (since `FileSystemWorkspace`'s confinement check
    /// resolves symlinks on both sides — `/tmp` itself is a symlink to `/private/tmp`
    /// on macOS, so the root must be pre-resolved or every legitimate path would fail
    /// the prefix check too).
    private func makeTempRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileSystemWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Basic operations

    @Test("Write then read a file at the root")
    func writeThenRead() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        try await workspace.writeFile(path: "hello.txt", content: "hello world")
        let content = try await workspace.readFile(path: "hello.txt")
        #expect(content == "hello world")
    }

    @Test("Write and read in a nested directory")
    func nestedDirectories() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        try await workspace.writeFile(path: "a/b/c.txt", content: "nested")
        let content = try await workspace.readFile(path: "a/b/c.txt")
        #expect(content == "nested")

        let listing = try await workspace.listFiles(path: "a/b")
        #expect(listing.contains("c.txt"))
    }

    @Test("List files at the root")
    func listFilesAtRoot() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        try await workspace.writeFile(path: "one.txt", content: "1")
        try await workspace.writeFile(path: "two.txt", content: "2")

        let listing = try await workspace.listFiles(path: ".")
        #expect(listing.contains("one.txt"))
        #expect(listing.contains("two.txt"))
    }

    @Test("Delete a file removes it")
    func deleteFile() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        try await workspace.writeFile(path: "doomed.txt", content: "bye")
        try await workspace.deleteFile(path: "doomed.txt")

        await #expect(throws: Error.self) {
            _ = try await workspace.readFile(path: "doomed.txt")
        }
    }

    @Test("Reading a missing file throws")
    func missingFileThrows() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        await #expect(throws: Error.self) {
            _ = try await workspace.readFile(path: "nope.txt")
        }
    }

    @Test("healthCheck reports true for an existing root")
    func healthCheckHealthy() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        let healthy = await workspace.healthCheck()
        #expect(healthy)
    }

    @Test("healthCheck reports false once the root is removed")
    func healthCheckUnhealthyAfterRemoval() async throws {
        let root = try makeTempRoot()
        let workspace = FileSystemWorkspace(rootURL: root)
        cleanup(root)

        let healthy = await workspace.healthCheck()
        #expect(!healthy)
    }

    @Test("listTools exposes the filesystem tool set")
    func listToolsExposesFilesystemTools() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        let tools = try await workspace.listTools()
        let ids = Set(tools.map(\.toolId))
        #expect(ids.contains("cat"))
        #expect(ids.contains("ls"))
        #expect(ids.contains("find"))
        #expect(ids.contains("search_files"))
        #expect(ids.contains("grep"))
        #expect(ids.contains("change_directory"))
    }

    @Test("executeTool routes ls through the workspace root")
    func executeToolRoutesListDirectory() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)
        try await workspace.writeFile(path: "present.txt", content: "x")

        let result = try await workspace.executeTool(id: "ls", parameters: ["path": .string(".")])
        #expect(result.success)
        #expect(result.output.contains("present.txt"))
    }

    @Test("executeTool surfaces toolExecutionNotSupported for unknown tool id")
    func executeToolUnknownId() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.executeTool(id: "not_a_real_tool", parameters: [:])
        }
    }

    // MARK: - Security: traversal, absolute-path escape, symlink escape

    @Test("Relative traversal outside the root is rejected without touching the filesystem")
    func relativeTraversalRejected() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        let outsideMarker = root.deletingLastPathComponent().appendingPathComponent("traversal-marker-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outsideMarker) }

        await #expect(throws: Error.self) {
            try await workspace.writeFile(path: "../\(outsideMarker.lastPathComponent)", content: "leaked")
        }
        #expect(!FileManager.default.fileExists(atPath: outsideMarker.path))

        await #expect(throws: Error.self) {
            _ = try await workspace.readFile(path: "../../etc/hosts")
        }
    }

    @Test("Absolute path outside the root is rejected")
    func absolutePathOutsideRootRejected() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }
        let workspace = FileSystemWorkspace(rootURL: root)

        await #expect(throws: Error.self) {
            _ = try await workspace.readFile(path: "/etc/hosts")
        }

        let escapeTarget = NSTemporaryDirectory() + "absolute-escape-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: escapeTarget) }

        await #expect(throws: Error.self) {
            try await workspace.writeFile(path: escapeTarget, content: "leaked")
        }
        #expect(!FileManager.default.fileExists(atPath: escapeTarget))
    }

    @Test("Symlink inside the root pointing outside the root is rejected on read and write")
    func symlinkEscapeRejected() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        // A genuine "outside" target, sibling to root, with sensitive content.
        let outsideDir = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("secret.txt")
        try "top secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        // Symlink inside the root that resolves to the outside file.
        let linkPath = root.appendingPathComponent("escape-link.txt")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: outsideFile)

        let workspace = FileSystemWorkspace(rootURL: root)

        await #expect(throws: Error.self) {
            _ = try await workspace.readFile(path: "escape-link.txt")
        }

        await #expect(throws: Error.self) {
            try await workspace.writeFile(path: "escape-link.txt", content: "overwritten")
        }

        // The outside file must remain untouched.
        let stillSecret = try String(contentsOf: outsideFile, encoding: .utf8)
        #expect(stillSecret == "top secret")
    }

    @Test("Symlinked directory inside the root pointing outside is rejected for listing")
    func symlinkedDirectoryEscapeRejected() async throws {
        let root = try makeTempRoot()
        defer { cleanup(root) }

        let outsideDir = root.deletingLastPathComponent()
            .appendingPathComponent("outside-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try "secret listing".write(
            to: outsideDir.appendingPathComponent("listed.txt"),
            atomically: true,
            encoding: .utf8
        )

        let linkPath = root.appendingPathComponent("escape-dir-link")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: outsideDir)

        let workspace = FileSystemWorkspace(rootURL: root)

        await #expect(throws: Error.self) {
            _ = try await workspace.listFiles(path: "escape-dir-link")
        }
    }
}
