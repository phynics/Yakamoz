import JSONSchema
import PKShared

/// YAK-47: the read-only filesystem tool ids that Yakamoz auto-approves at its tool
/// registration seam, so they execute without surfacing a per-call approval banner.
///
/// Mirrored from PositronicKit's `PKShared/Tools/Filesystem/`:
/// `ReadFileTool` (`cat`), `ListDirectoryTool` (`ls`), `FindFileTool` (`find`),
/// `SearchFilesTool` (`search_files`), `SearchFileContentTool` (`grep`). All ship from
/// PK 1.0.0 with `requiresPermission = true`. Yakamoz is a local, single-user,
/// non-sandboxed dev app whose folder-workspace tools are already path-confined to the
/// attached folder (YAK-32 path-traversal hardening), so per-call approval for *reads*
/// is friction without a matching risk. Write/execute capabilities (`terminal_run` and
/// any future write tool) keep their gates.
///
/// This is an **allowlist**, not "everything except terminal": a future write tool must
/// not sail through un-gated by default. The ids are verified against the PK tool
/// definitions (the ticket's `read_file` guess is wrong — `ReadFileTool.id == "cat"`).
public enum ReadOnlyToolApproval {
    public static let autoApprovedToolIds: Set<String> = [
        "cat",
        "ls",
        "find",
        "search_files",
        "grep",
    ]
}

public extension AnyTool {
    /// Returns a copy of this tool with `requiresPermission = false`, forwarding every
    /// other member and preserving `provenance`. Applied at Yakamoz's tool registration
    /// seam (`YakamozRuntime.resolveTools`) to the ids in `ReadOnlyToolApproval` so the
    /// read-only filesystem tools skip the approval gate entirely. Mirrors TEX-1's
    /// `withExplanationParameter()` decorator approach; the two decorators compose at the
    /// same seam and preserve each other's effects (schema + flag).
    func withoutPermissionRequirement() -> AnyTool {
        AnyTool(UnpermissionedTool(wrapped: self), provenance: provenance)
    }
}

private struct UnpermissionedTool: Tool {
    let wrapped: AnyTool

    var callName: String { wrapped.callName }
    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var requiresPermission: Bool { false }
    var usageExample: String? { wrapped.usageExample }
    var parametersSchema: Schema { wrapped.parametersSchema }

    func canExecute() async -> Bool {
        await wrapped.canExecute()
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        try await wrapped.execute(parameters: parameters)
    }

    func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String {
        wrapped.summarize(parameters: parameters, result: result)
    }
}
