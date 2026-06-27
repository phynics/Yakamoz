import Foundation
import PKShared
import PositronicKit

/// A `WorkspaceProtocol` implementation backed by an agent-driven PTY shell session rooted at
/// `rootURL`, instead of a filesystem confinement boundary.
///
/// Unlike `FileSystemWorkspace`, this workspace exposes no direct file operations — a terminal
/// is a shell, not a file store — and routes its five tool ids (`terminal_run`/`terminal_read`/
/// `terminal_send_input`/`terminal_interrupt`/`terminal_wait`) to the corresponding `Tool` types
/// in `TerminalTools.swift`, each constructed with this workspace's `id`, `registry`, and
/// `rootURL` (and, for `terminal_run` only, `approver`).
public actor TerminalWorkspace: WorkspaceProtocol {
    public let id: UUID
    public let rootURL: URL
    public let registry: TerminalSessionRegistry
    public let approver: any TerminalCommandApproving
    private let displayName: String

    public init(
        id: UUID = UUID(),
        rootURL: URL,
        registry: TerminalSessionRegistry,
        approver: any TerminalCommandApproving,
        displayName: String? = nil
    ) {
        self.id = id
        self.rootURL = rootURL
        self.registry = registry
        self.approver = approver
        self.displayName = displayName ?? rootURL.lastPathComponent
    }

    public nonisolated var reference: WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: .terminal(rootPath: rootURL.path),
            location: .attached,
            tools: Self.toolIds.map { .known(id: $0) },
            rootPath: rootURL.path,
            trustLevel: .full
        )
    }

    // MARK: - WorkspaceProtocol: file operations

    /// A terminal is a shell, not a file store: none of the direct file operations are supported.
    public func readFile(path _: String) async throws -> String {
        throw WorkspaceError.toolExecutionNotSupported
    }

    public func writeFile(path _: String, content _: String) async throws {
        throw WorkspaceError.toolExecutionNotSupported
    }

    public func listFiles(path _: String) async throws -> [String] {
        throw WorkspaceError.toolExecutionNotSupported
    }

    public func deleteFile(path _: String) async throws {
        throw WorkspaceError.toolExecutionNotSupported
    }

    public func healthCheck() async -> Bool {
        true
    }

    // MARK: - WorkspaceProtocol: tool routing

    /// The terminal tool ids this workspace exposes, in display order.
    static let toolIds = ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"]

    public func listTools() async throws -> [ToolReference] {
        Self.toolIds.map { .known(id: $0) }
    }

    public func executeTool(id toolId: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        let rawParameters = parameters.toAnyDictionary
        let tool: any Tool
        switch toolId {
        case "terminal_run":
            tool = TerminalRunTool(workspaceId: id, registry: registry, rootURL: rootURL, approver: approver)
        case "terminal_read":
            tool = TerminalReadTool(workspaceId: id, registry: registry, rootURL: rootURL)
        case "terminal_send_input":
            tool = TerminalSendInputTool(workspaceId: id, registry: registry, rootURL: rootURL)
        case "terminal_interrupt":
            tool = TerminalInterruptTool(workspaceId: id, registry: registry, rootURL: rootURL)
        case "terminal_wait":
            tool = TerminalWaitTool(workspaceId: id, registry: registry, rootURL: rootURL)
        default:
            throw WorkspaceError.toolExecutionNotSupported
        }

        return try await tool.execute(parameters: rawParameters)
    }
}
