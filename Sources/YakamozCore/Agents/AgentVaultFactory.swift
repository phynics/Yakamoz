import Foundation

/// Builds and maintains the app-managed, Obsidian-compatible vault directory for each
/// `AgentModel`: `NOTES.md` (agent-curated, never overwritten once it has content),
/// `WORKFLOW.md` (app-owned, always regenerated from the latest template), and
/// `Memory/INDEX.md` (agent-curated once seeded).
///
/// Injecting `baseDirectory` (rather than hardcoding `FileManager`'s application-support
/// lookup) is what lets tests point the factory at a temp directory instead of the real
/// `~/Library/Application Support`.
/// `FileManager` is thread-safe; this immutable wrapper documents the unchecked boundary.
/// Without it Swift 6 diagnoses the stored `FileManager` as non-Sendable.
public struct AgentVaultFactory: @unchecked Sendable {
    private let baseDirectory: URL
    private let fileManager: FileManager

    /// - Parameter baseDirectory: Root under which per-agent vaults are namespaced
    ///   (`<baseDirectory>/Agents/<agent-id>/`). Defaults to
    ///   `~/Library/Application Support/Yakamoz`. Tests should inject a temp directory.
    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.baseDirectory = appSupport.appending(path: "Yakamoz", directoryHint: .isDirectory)
        }
        self.fileManager = fileManager
    }

    /// Deterministic, per-agent-id vault root: `<baseDirectory>/Agents/<agent-id>/`.
    public func vaultRoot(for agentId: UUID) -> URL {
        baseDirectory.appending(path: "Agents/\(agentId.uuidString)", directoryHint: .isDirectory)
    }

    /// Idempotently creates the vault directory tree for `agent`. Existing `NOTES.md` and
    /// `Memory/INDEX.md` content is preserved; `WORKFLOW.md` is always (re)written to the
    /// latest template.
    @discardableResult
    public func createVault(for agent: AgentModel) throws -> URL {
        let root = vaultRoot(for: agent.id)
        let memoryDir = root.appending(path: "Memory", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        } catch {
            throw AgentVaultError.directoryCreationFailed(path: memoryDir.path, underlying: "\(error)")
        }

        try writeIfMissing(
            at: root.appending(path: "NOTES.md"),
            contents: Self.notesTemplate
        )
        try writeIfMissing(
            at: memoryDir.appending(path: "INDEX.md"),
            contents: Self.memoryIndexTemplate
        )
        try regenerateWorkflowTemplate(for: agent)

        return root
    }

    /// Overwrites `WORKFLOW.md` with the latest app-owned template. Safe to call any time
    /// (e.g. after a template update); never touches `NOTES.md` or `Memory/`.
    public func regenerateWorkflowTemplate(for agent: AgentModel) throws {
        let root = vaultRoot(for: agent.id)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.workflowTemplate.write(
                to: root.appending(path: "WORKFLOW.md"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw AgentVaultError.writeFailed(path: root.appending(path: "WORKFLOW.md").path, underlying: "\(error)")
        }
    }

    /// Recursively deletes the vault directory for `agentId`. Callers are responsible for
    /// confirming with the user before calling this — the factory performs no confirmation.
    public func deleteVault(for agentId: UUID) throws {
        let root = vaultRoot(for: agentId)
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            try fileManager.removeItem(at: root)
        } catch {
            throw AgentVaultError.deleteFailed(path: root.path, underlying: "\(error)")
        }
    }

    private func writeIfMissing(at url: URL, contents: String) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw AgentVaultError.writeFailed(path: url.path, underlying: "\(error)")
        }
    }
}

extension AgentVaultFactory {
    static let notesTemplate =
        "<!-- standing facts, preferences, current focus — kept small, always injected -->\n"

    static let memoryIndexTemplate = "# Memory Index\n"

    static let workflowTemplate = """
    # How to use this vault

    This is a plain markdown vault, Obsidian-compatible — `[[wiki-links]]` work here.

    - Keep `NOTES.md` small and curated: standing facts, preferences, and your current
      focus. It is injected into every conversation, so treat it as a whiteboard, not a log.
    - Store durable knowledge as one-topic notes under `Memory/`, one file per topic, each
      starting with a `description:` YAML frontmatter line, and linked to related notes
      with `[[wiki-links]]`.
    - Whenever you add or remove a `Memory/` note, update `Memory/INDEX.md` in the same
      edit: one line per note, `- [[note-name]] — one-line hook`.
    - To recall something: read `Memory/INDEX.md` first, open the matching note, then
      follow its links.
    - Everything else in this vault is scratch space.

    Do not edit this file; it is regenerated by the app.
    """
}

/// Structured errors for `AgentVaultFactory` operations, conforming to the repo-wide
/// `Throwable`-style convention (stable case set, user-friendly messages for surfacing to
/// logs/tools).
public enum AgentVaultError: Error, Sendable {
    case directoryCreationFailed(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case deleteFailed(path: String, underlying: String)
}

extension AgentVaultError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .directoryCreationFailed(path, underlying):
            "Failed to create vault directory at \(path): \(underlying)"
        case let .writeFailed(path, underlying):
            "Failed to write vault file at \(path): \(underlying)"
        case let .deleteFailed(path, underlying):
            "Failed to delete vault at \(path): \(underlying)"
        }
    }
}
