import Foundation
import PKPrompt
import PositronicKit

/// Injects the app-owned instructional vault files for the active backend/agent instance.
public struct AgentVaultPromptSectionProvider: PromptSectionProviding {
    public static let sectionPrefix = "yakamoz.agent-vault."
    private let rootForAgent: @Sendable (UUID) -> URL

    public init(rootForAgent: @escaping @Sendable (UUID) -> URL = {
        AgentVaultFactory().vaultRoot(for: $0)
    }) {
        self.rootForAgent = rootForAgent
    }

    public func sections(for context: PromptBuildContext) async -> [any Prompt] {
        guard let agentID = context.agentInstanceId else { return [] }
        let root = rootForAgent(agentID)
        let files = [("workflow", "WORKFLOW.md"), ("notes", "NOTES.md"), ("index", "Memory/INDEX.md")]
        return files.compactMap { key, path -> (any Prompt)? in
            let url = root.appending(path: path)
            guard let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty else { return nil }
            let content = key == "notes" || key == "index" ? capped(value) : value
            return TextPrompt(content, id: Self.sectionPrefix + key, priority: PromptPriority.high.rawValue, compression: .keep, cachePolicy: .volatile)
        }
    }

    private func capped(_ value: String) -> String {
        let limit = 8 * 1024
        guard value.utf8.count > limit else { return value }
        let prefix = String(decoding: value.utf8.prefix(limit), as: UTF8.self)
        return prefix + "\n\n[truncated by Yakamoz]"
    }
}
