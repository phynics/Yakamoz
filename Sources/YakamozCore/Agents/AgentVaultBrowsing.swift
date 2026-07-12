import Foundation

/// One segment of vault prose: plain text, or a `[[wiki-link]]`'s inner text.
public enum VaultTextSegment: Sendable, Equatable {
    case text(String)
    case wikiLink(String)
}

/// One `Memory/*.md` note in an agent's vault, as listed by the Vault tab.
public struct VaultMemoryNote: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let preview: String

    public init(id: String, title: String, preview: String) {
        self.id = id
        self.title = title
        self.preview = preview
    }
}

/// ATW-8: read/write helpers for the Vault tab (`NOTES.md`, `Memory/` listing) plus a
/// minimal `[[wiki-link]]` renderer. Kept separate from `AgentVaultFactory` (which owns
/// vault *creation*/template regeneration) since this is read/display-oriented and has no
/// opinion on the vault's initial contents.
public enum AgentVaultBrowsing {
    /// Reads `NOTES.md` from the agent's vault. Returns an empty string if the file is
    /// missing or unreadable (a fresh/broken vault degrades to an empty editor rather than
    /// throwing on view load).
    public static func readNotes(agent: AgentModel, fileManager _: FileManager = .default) -> String {
        let url = notesURL(for: agent)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Overwrites `NOTES.md` with `contents`.
    public static func writeNotes(agent: AgentModel, contents: String, fileManager: FileManager = .default) throws {
        let url = notesURL(for: agent)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Lists every `Memory/*.md` note except `INDEX.md` (the curated index itself, not a
    /// note), sorted by filename. Each note's `preview` is its first non-empty line with any
    /// leading `description:` frontmatter marker stripped.
    public static func listMemoryNotes(agent: AgentModel, fileManager: FileManager = .default) -> [VaultMemoryNote] {
        let memoryDir = memoryURL(for: agent)
        guard let entries = try? fileManager.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "INDEX.md" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let title = url.deletingPathExtension().lastPathComponent
                let preview = firstPreviewLine(of: contents)
                return VaultMemoryNote(id: url.lastPathComponent, title: title, preview: preview)
            }
    }

    /// Splits `text` into plain-prose and `[[wiki-link]]` segments, in order. Kept as plain
    /// data (no `AttributedString`/SwiftUI dependency) so `YakamozCore` stays UI-framework-free;
    /// the app target's Vault view maps `.wikiLink` segments to styled inline text.
    public static func renderWikiLinks(_ text: String) -> [VaultTextSegment] {
        var segments: [VaultTextSegment] = []
        var remainder = Substring(text)

        while let openRange = remainder.range(of: "[[") {
            let before = remainder[remainder.startIndex ..< openRange.lowerBound]
            if !before.isEmpty { segments.append(.text(String(before))) }

            let afterOpen = remainder[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "]]") else {
                segments.append(.text(String(remainder[openRange.lowerBound...])))
                remainder = Substring("")
                break
            }

            let linkText = String(afterOpen[afterOpen.startIndex ..< closeRange.lowerBound])
            segments.append(.wikiLink(linkText))
            remainder = afterOpen[closeRange.upperBound...]
        }
        if !remainder.isEmpty { segments.append(.text(String(remainder))) }
        return segments
    }

    private static func firstPreviewLine(of contents: String) -> String {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("description:") {
                return trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return ""
    }

    private static func notesURL(for agent: AgentModel) -> URL {
        URL(fileURLWithPath: agent.vaultPath, isDirectory: true).appending(path: "NOTES.md")
    }

    private static func memoryURL(for agent: AgentModel) -> URL {
        URL(fileURLWithPath: agent.vaultPath, isDirectory: true).appending(path: "Memory", directoryHint: .isDirectory)
    }
}
