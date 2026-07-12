import SwiftData
import SwiftUI
import YakamozCore

struct ContentView: View {
    @State private var selection: SidebarSelection?
    @State private var monadSelection: MonadSidebarSelection?
    @State private var operationMode: OperationMode = AppSettingsStore().lastOperationMode
    @State private var monadProfile: MonadProfile? = AppSettingsStore().lastMonadProfile

    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]
    @Query(filter: ConversationListQuery.standardPredicate) private var conversations: [ConversationModel]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                .safeAreaInset(edge: .top) {
                    modeToggle
                }
        } detail: {
            detail
        }
    }

    // MARK: - Mode toggle (YAK-MON-4: clearly distinguishes Local vs Monad mode)

    private var modeToggle: some View {
        Picker("Mode", selection: modeBinding) {
            Text("Local").tag(OperationMode.local)
            Text("Monad").tag(OperationMode.monad)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .accessibilityLabel("Operation Mode")
    }

    private var modeBinding: Binding<OperationMode> {
        Binding(
            get: { operationMode },
            set: { newMode in
                operationMode = newMode
                AppSettingsStore().lastOperationMode = newMode
                monadProfile = AppSettingsStore().lastMonadProfile
            }
        )
    }

    // MARK: - Sidebar (mode-routed)

    @ViewBuilder
    private var sidebar: some View {
        switch operationMode {
        case .local:
            AgentSidebarView(selection: $selection)
        case .monad:
            MonadSidebarView(selection: $monadSelection, profile: monadProfile)
        }
    }

    // MARK: - Detail (mode-routed)

    @ViewBuilder
    private var detail: some View {
        switch operationMode {
        case .local:
            localDetail
        case .monad:
            monadDetail
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
        case nil:
            unavailable
        }
    }

    @ViewBuilder
    private var monadDetail: some View {
        switch monadSelection {
        case let .agent(agentId):
            MonadAgentDetailView(agentId: agentId, profile: monadProfile, selection: $monadSelection)
        case let .timeline(timelineId):
            MonadTimelineSummaryView(timelineId: timelineId, profile: monadProfile)
        case nil:
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Select an Agent or Timeline",
            systemImage: "bubble.left.and.bubble.right"
        )
    }
}
