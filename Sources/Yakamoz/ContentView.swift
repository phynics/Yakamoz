import SwiftData
import SwiftUI
import YakamozCore
import YakamozNetwork

struct ContentView: View {
    @State private var selection: SidebarSelection?

    @Environment(\.networkSession) private var networkSession
    @Environment(\.gnosticBackend) private var gnosticBackend

    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]
    @Query(filter: ConversationListQuery.standardPredicate) private var conversations: [ConversationModel]

    var body: some View {
        NavigationSplitView {
            AgentSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            localDetail
        }
    }

    @ViewBuilder
    private var localDetail: some View {
        switch selection {
        case let .agent(agentId):
            if let agent = agents.first(where: { $0.id == agentId }) {
                AgentDetailView(agent: agent, onDeleted: { selection = nil })
            } else {
                unavailable
            }
        case let .timeline(timelineId):
            if let conversation = conversations.first(where: { $0.id == timelineId }) {
                ChatView(conversation: conversation)
            } else {
                unavailable
            }
        case let .network(networkSelection):
            if let networkSession, let gnosticBackend {
                networkDetail(
                    networkSelection,
                    session: networkSession,
                    backend: gnosticBackend
                )
            } else {
                unavailable
            }
        case nil:
            unavailable
        }
    }

    /// Timelines open the network chat surface (#10); Ascendants and Workspaces keep
    /// the browsable detail surface until their own interaction tickets land.
    @ViewBuilder
    private func networkDetail(
        _ selection: NetworkSidebarSelection,
        session: NetworkClientSession,
        backend: GnosticBackend
    ) -> some View {
        if case let .timeline(key) = selection {
            NetworkChatView(key: key, session: session, backend: backend)
        } else {
            NetworkPlaceholderDetailView(selection: selection, session: session)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Select an Agent or Timeline",
            systemImage: "bubble.left.and.bubble.right"
        )
    }
}
