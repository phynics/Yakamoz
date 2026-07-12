import Foundation
import PKPrompt
import PositronicKit
import SwiftData

/// The minimal agent fields `AgentVaultPromptSectionProvider` needs: the agent `id` (to
/// resolve the vault root via `AgentVaultFactory.vaultRoot(for:)`) and the `instructions`
/// text (injected as the first system section).
///
/// A value type rather than `AgentModel` itself: `@Model` classes are intentionally not
/// `Sendable` (SwiftData marks that conformance unavailable), so the runtime's lookup
/// closure copies the two needed fields out of the fetched `AgentModel` into this struct.
public struct AgentVaultSnapshot: Sendable, Equatable {
    public let id: UUID
    public let instructions: String

    public init(id: UUID, instructions: String) {
        self.id = id
        self.instructions = instructions
    }
}

/// Injects the app-owned instructional vault files for the active backend/agent instance.
///
/// When a timeline's operator is agent X, the system context gains, in order:
/// **agent instructions → `WORKFLOW.md` → `NOTES.md` → `Memory/INDEX.md`** (spec §4.3).
/// Memory note bodies are never injected — the agent reads them on demand with file tools.
/// Missing/empty files inject nothing (no error). `NOTES.md` and `Memory/INDEX.md` are
/// capped at ~8 KB each with a visible truncation marker so a runaway agent cannot blow
/// up its own context.
///
/// `PromptBuildContext.agentInstanceId` is the PositronicKit **backend instance id**
/// (`AgentModel.backendInstanceId`), not the `AgentModel.id` that keys the vault root.
/// `agentForInstance` resolves that backend id back to the owning agent snapshot. When
/// unwired (default), nothing is injected — the runtime supplies the real lookup.
public struct AgentVaultPromptSectionProvider: PromptSectionProviding {
    public static let sectionPrefix = "yakamoz.agent-vault."

    private let agentForInstance: @Sendable (UUID) async -> AgentVaultSnapshot?
    private let rootForAgent: @Sendable (UUID) -> URL
    private let isHomeTimeline: @Sendable (UUID) async -> Bool

    /// - Parameters:
    ///   - agentForInstance: Resolves a backend instance id to the owning agent snapshot
    ///     (for its `id` and `instructions`). Returns `nil` for an unknown/absent instance,
    ///     in which case nothing is injected. Defaults to `{ _ in nil }` (no injection)
    ///     because there is no shared `ModelContainer` accessor; the runtime's `makeKit`
    ///     supplies the real lookup, capturing the `ModelContainer` it already holds.
    ///   - rootForAgent: Maps an `AgentModel.id` to its vault root URL. Defaults to
    ///     `AgentVaultFactory().vaultRoot(for:)`.
    public init(
        agentForInstance: @escaping @Sendable (UUID) async -> AgentVaultSnapshot? = { _ in nil },
        rootForAgent: @escaping @Sendable (UUID) -> URL = { AgentVaultFactory().vaultRoot(for: $0) },
        isHomeTimeline: @escaping @Sendable (UUID) async -> Bool = { _ in false }
    ) {
        self.agentForInstance = agentForInstance
        self.rootForAgent = rootForAgent
        self.isHomeTimeline = isHomeTimeline
    }

    public func sections(for context: PromptBuildContext) async -> [any Prompt] {
        guard let instanceID = context.agentInstanceId,
              let agent = await agentForInstance(instanceID)
        else { return [] }

        let root = rootForAgent(agent.id)
        var sections: [any Prompt] = []

        // Agent instructions first (spec §4.3 ordering).
        if !agent.instructions.isEmpty {
            sections.append(
                TextPrompt(
                    agent.instructions,
                    id: Self.sectionPrefix + "instructions",
                    priority: PromptPriority.high.rawValue,
                    compression: .keep,
                    cachePolicy: .volatile
                )
            )
        }

        if await isHomeTimeline(context.timelineId) {
            sections.append(
                TextPrompt(
                    AgentVaultFactory.homeTimelineTemplate,
                    id: Self.sectionPrefix + "home",
                    priority: PromptPriority.high.rawValue,
                    compression: .keep,
                    cachePolicy: .volatile
                )
            )
        }

        // Then the vault files: WORKFLOW (uncapped, app-owned), NOTES and INDEX (capped).
        for (key, path, cap) in [
            ("workflow", "WORKFLOW.md", false),
            ("notes", "NOTES.md", true),
            ("index", "Memory/INDEX.md", true),
        ] as [(String, String, Bool)] {
            let url = root.appending(path: path)
            guard let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty else { continue }
            let content = cap ? Self.capped(value) : value
            sections.append(
                TextPrompt(
                    content,
                    id: Self.sectionPrefix + key,
                    priority: PromptPriority.high.rawValue,
                    compression: .keep,
                    cachePolicy: .volatile
                )
            )
        }

        return sections
    }

    /// Caps `value` at ~8 KB (UTF-8) and appends a visible truncation marker.
    static func capped(_ value: String) -> String {
        let limit = 8 * 1024
        guard value.utf8.count > limit else { return value }
        let prefix = String(decoding: value.utf8.prefix(limit), as: UTF8.self)
        return prefix + "\n\n[truncated by Yakamoz]"
    }

    /// Builds the default `agentForInstance` closure used by `YakamozRuntime.makeKit`:
    /// reads the `AgentModel` whose `backendInstanceId` matches the given instance id
    /// from the supplied `ModelContainer`, then copies the two needed fields into an
    /// `AgentVaultSnapshot` (because `AgentModel` is a non-`Sendable` `@Model`).
    /// `ModelContainer` is `Sendable`; the `ModelContext` is created and consumed within
    /// the closure so no actor hop is required from the `@Sendable` call site.
    public static func lookup(in container: ModelContainer) -> @Sendable (UUID) async -> AgentVaultSnapshot? {
        { instanceID in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<AgentModel>(
                predicate: #Predicate { $0.backendInstanceId == instanceID }
            )
            guard let agent = try? context.fetch(descriptor).first else { return nil }
            return AgentVaultSnapshot(id: agent.id, instructions: agent.instructions)
        }
    }

    /// Resolves whether a prompt's timeline is an agent home timeline without sharing a
    /// `ModelContext` across concurrency domains.
    public static func homeTimelineLookup(in container: ModelContainer) -> @Sendable (UUID) async -> Bool {
        { timelineID in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineID })
            return (try? context.fetch(descriptor).first?.isHomeTimeline) ?? false
        }
    }
}
