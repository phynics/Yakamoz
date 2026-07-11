import Foundation
import Testing
@testable import YakamozCore

@Suite("AgentSidebarPresentation")
struct AgentSidebarPresentationTests {
    @Test("Groups timelines under their operating agent, newest first")
    func groupsUnderOperatingAgent() throws {
        let agent = AgentModel(name: "Ada", instructions: "", vaultPath: "/tmp/ada")
        let older = ConversationModel(title: "Older", createdAt: Date(timeIntervalSince1970: 0), agentId: agent.id)
        let newer = ConversationModel(title: "Newer", createdAt: Date(timeIntervalSince1970: 100), agentId: agent.id)

        let groups = AgentSidebarPresentation.groups(agents: [agent], conversations: [older, newer])

        let agentGroup = try #require(groups.first { $0.agentId == agent.id })
        #expect(agentGroup.timelines.map(\.id) == [newer.id, older.id])
    }

    @Test("Excludes home timelines from an agent's operated group")
    func excludesHomeTimelines() throws {
        let agent = AgentModel(name: "Ada", instructions: "", vaultPath: "/tmp/ada")
        let home = ConversationModel(title: "Home", agentId: agent.id, isHomeTimeline: true)
        let regular = ConversationModel(title: "Regular", agentId: agent.id)

        let groups = AgentSidebarPresentation.groups(agents: [agent], conversations: [home, regular])

        let agentGroup = try #require(groups.first { $0.agentId == agent.id })
        #expect(agentGroup.timelines.map(\.id) == [regular.id])
    }

    @Test("Unassigned group contains only timelines with no operator")
    func unassignedGroupMembership() throws {
        let agent = AgentModel(name: "Ada", instructions: "", vaultPath: "/tmp/ada")
        let assigned = ConversationModel(title: "Assigned", agentId: agent.id)
        let unassigned = ConversationModel(title: "Unassigned", agentId: nil)

        let groups = AgentSidebarPresentation.groups(agents: [agent], conversations: [assigned, unassigned])

        let unassignedGroup = try #require(groups.first { $0.isUnassigned })
        #expect(unassignedGroup.timelines.map(\.id) == [unassigned.id])
    }

    @Test("Agents are sorted by name, case-insensitively")
    func agentsSortedByName() {
        let bob = AgentModel(name: "bob", instructions: "", vaultPath: "/tmp/bob")
        let alice = AgentModel(name: "Alice", instructions: "", vaultPath: "/tmp/alice")

        let groups = AgentSidebarPresentation.groups(agents: [bob, alice], conversations: [])

        #expect(groups.map(\.agentName) == ["Alice", "bob", "Unassigned"])
    }

    @Test("Send is disabled without an operator, enabled once assigned")
    func sendDisabledPredicate() {
        #expect(AgentSidebarPresentation.isSendDisabled(agentId: nil) == true)
        #expect(AgentSidebarPresentation.isSendDisabled(agentId: UUID()) == false)
    }
}
