import Foundation

/// YAK-MON-4: distinguishes a server agent *instance* (a live agent with its own workspace
/// and private timeline) from an *template* (a reusable definition an instance can be
/// created from). `BackendAgentSummary` (YAK-MON-2) is intentionally kept generic
/// (id/name only, "assign this agent to a timeline") — Monad mode's sidebar needs the
/// richer distinction the ticket calls out ("server agents/templates"), so this is a
/// separate, additive type rather than growing `BackendAgentSummary`'s shape for every
/// backend.
public struct MonadAgentSummary: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case instance
        case template
    }

    public let id: UUID
    public let kind: Kind
    public let name: String
    public let description: String

    public init(id: UUID, kind: Kind, name: String, description: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
    }
}

/// Monad-mode-only surface: list server agent instances/templates, and the timelines
/// belonging to a given agent instance. Deliberately separate from `BackendAgentSelecting`
/// (which only covers "assign an agent id to a timeline", a shape both backends share) —
/// this is Monad-specific navigation data with no local-mode equivalent, so it is not part
/// of the `YakamozBackend` typealias.
public protocol MonadAgentListing: Sendable {
    func listAgentInstances() async throws -> [MonadAgentSummary]
    func listAgentTemplates() async throws -> [MonadAgentSummary]
    func listTimelines(forAgent agentId: UUID) async throws -> [BackendTimelineSummary]
}
