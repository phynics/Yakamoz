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

    /// Timelines open the network chat surface (#10); Ascendants and Workspaces open
    /// detail surfaces whose timeline links route back through the sidebar selection.
    @ViewBuilder
    private func networkDetail(
        _ networkSelection: NetworkSidebarSelection,
        session: NetworkClientSession,
        backend: GnosticBackend
    ) -> some View {
        let openTimeline: (NetworkObjectKey) -> Void = { selection = .network(.timeline($0)) }
        switch networkSelection {
        case let .timeline(key):
            NetworkChatView(key: key, session: session, backend: backend)
        case let .ascendant(key):
            NetworkAscendantDetailView(key: key, session: session, onOpenTimeline: openTimeline)
        case let .workspace(key):
            NetworkWorkspaceDetailView(key: key, session: session, onOpenTimeline: openTimeline)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Select an Agent or Timeline",
            systemImage: "bubble.left.and.bubble.right"
        )
    }
}
