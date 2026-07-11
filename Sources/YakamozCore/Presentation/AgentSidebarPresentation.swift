import Foundation

/// One sidebar section: either an agent's operated non-home timelines, or the
/// "Unassigned" group of timelines with no operator (`agentId == nil`).
public struct AgentSidebarGroup: Equatable, Identifiable {
    /// `nil` for the Unassigned group.
    public let agentId: UUID?
    public let agentName: String
    /// Non-home timelines belonging to this group, newest first.
    public let timelines: [ConversationModel]

    public var id: UUID {
        agentId ?? AgentSidebarPresentation.unassignedGroupId
    }

    public var isUnassigned: Bool {
        agentId == nil
    }

    public init(agentId: UUID?, agentName: String, timelines: [ConversationModel]) {
        self.agentId = agentId
        self.agentName = agentName
        self.timelines = timelines
    }
}

/// ATW-8: pure grouping/ordering logic for the agents-centric sidebar, kept free of
/// SwiftUI/`@Query` so it is directly unit-testable. `ConversationModel` is a SwiftData
/// `@Model` (a reference type) but this enum only reads its already-fetched properties.
public enum AgentSidebarPresentation {
    /// Stable synthetic id for the "Unassigned" group row.
    public static let unassignedGroupId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Builds one group per agent (sorted by name, case-insensitive) followed by a
    /// trailing Unassigned group. Each group's timelines exclude home timelines (a home
    /// timeline is reached only through its agent's Chat tab, never listed as an operated
    /// timeline) and are sorted newest-first by `createdAt`.
    public static func groups(agents: [AgentModel], conversations: [ConversationModel]) -> [AgentSidebarGroup] {
        let sortedAgents = agents.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var groups = sortedAgents.map { agent -> AgentSidebarGroup in
            let timelines = conversations
                .filter { $0.agentId == agent.id && !$0.isHomeTimeline }
                .sorted { $0.createdAt > $1.createdAt }
            return AgentSidebarGroup(agentId: agent.id, agentName: agent.name, timelines: timelines)
        }

        let unassigned = conversations
            .filter { $0.agentId == nil && !$0.isHomeTimeline }
            .sorted { $0.createdAt > $1.createdAt }
        groups.append(AgentSidebarGroup(agentId: nil, agentName: "Unassigned", timelines: unassigned))

        return groups
    }

    /// Send is disabled for a timeline until an operator is assigned (ATW-8 requirement 5).
    /// A home timeline always has an operator (its owning agent) by construction, so this
    /// only ever disables plain operator-less timelines.
    public static func isSendDisabled(agentId: UUID?) -> Bool {
        agentId == nil
    }
}
