import Foundation

/// One sidebar section in Monad mode: server agent instances, or server agent templates.
/// Mirrors the shape of `AgentSidebarGroup` (local mode) but is deliberately a distinct
/// type — Monad mode's data (server agents/templates) never mixes with local Yakamoz
/// agents/vaults (YAK-MON-4 requirement: no unified mixed local/server agent list).
public struct MonadSidebarSection: Equatable, Identifiable {
    public let id: MonadAgentSummary.Kind
    public let title: String
    public let agents: [MonadAgentSummary]

    public init(id: MonadAgentSummary.Kind, title: String, agents: [MonadAgentSummary]) {
        self.id = id
        self.title = title
        self.agents = agents
    }
}

/// Pure grouping/ordering logic for the Monad-mode sidebar, kept free of SwiftUI/network
/// so it is directly unit-testable, matching the `AgentSidebarPresentation` pattern for the
/// local-mode sidebar.
public enum MonadSidebarPresentation {
    /// Builds an "Agents" section (server agent instances) followed by a "Templates"
    /// section (server agent templates), each sorted by name, case-insensitively. A kind
    /// with no items produces no section at all (no empty section headers).
    public static func sections(instances: [MonadAgentSummary], templates: [MonadAgentSummary]) -> [MonadSidebarSection] {
        var sections: [MonadSidebarSection] = []
        if !instances.isEmpty {
            sections.append(MonadSidebarSection(id: .instance, title: "Agents", agents: sortedByName(instances)))
        }
        if !templates.isEmpty {
            sections.append(MonadSidebarSection(id: .template, title: "Templates", agents: sortedByName(templates)))
        }
        return sections
    }

    private static func sortedByName(_ agents: [MonadAgentSummary]) -> [MonadAgentSummary] {
        agents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
