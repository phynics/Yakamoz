import SwiftData
import SwiftUI
import YakamozCore
import YakamozNetwork

/// ATW-8: the operator-centric sidebar. Selecting an operator opens its home conversation;
/// expanding it reveals its other conversations, newest first. A trailing "Unassigned" group
/// holds conversations with no operator. The toolbar creates operators and conversations;
/// each operator row's context menu edits, extends, or deletes it
/// (docs/design/interaction-paradigm.md §3.2).
struct AgentSidebarView: View {
    @Binding var selection: SidebarSelection?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Environment(\.uiCoordinator) private var coordinator
    @Environment(\.networkSettings) private var networkSettings
    @Environment(\.networkSession) private var networkSession

    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]
    @Query(filter: ConversationListQuery.standardPredicate, sort: \ConversationModel.createdAt, order: .reverse)
    private var conversations: [ConversationModel]

    @State private var expandedAgentIds: Set<UUID> = []
    @State private var creationError: String?
    @State private var pendingOperatorDeletion: AgentSidebarGroup?

    @Environment(\.openWindow) private var openWindow

    private var groups: [AgentSidebarGroup] {
        AgentSidebarPresentation.groups(agents: agents, conversations: conversations)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                if group.isUnassigned {
                    unassignedSection(group)
                } else {
                    agentSection(group)
                }
            }

            if let networkSettings, networkSettings.isEnabled, let networkSession {
                NetworkSidebarSection(session: networkSession, selection: selection)
            }
        }
        .animation(.default, value: conversations.map(\.id))
        .navigationTitle("Operators")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        createAgent()
                    } label: {
                        Label("New Operator", systemImage: "person.crop.circle.badge.plus")
                    }
                    Button {
                        createUnassignedTimeline()
                    } label: {
                        Label("New Conversation", systemImage: "plus.bubble")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .onChange(of: coordinator.newChatToken) { _, _ in
            createUnassignedTimeline()
        }
        .confirmationDialog(
            "Delete \(pendingOperatorDeletion?.agentName ?? "Operator")?",
            isPresented: Binding(
                get: { pendingOperatorDeletion != nil },
                set: { if !$0 { pendingOperatorDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = pendingOperatorDeletion { deleteOperator(group.id) }
                pendingOperatorDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingOperatorDeletion = nil }
        } message: {
            Text("This deletes the operator's home conversation and vault. Conversations it merely operated become unassigned.")
        }
        .errorAlert("Couldn't Complete Action", message: $creationError)
    }

    private func agentSection(_ group: AgentSidebarGroup) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
            ForEach(group.timelines) { timeline in
                TimelineRow(conversation: timeline)
                    .tag(SidebarSelection.timeline(timeline.id))
            }
            .onDelete { offsets in deleteTimelines(offsets, from: group.timelines) }
        } label: {
            Label(group.agentName, systemImage: "person.crop.circle")
                .tag(SidebarSelection.agent(group.id))
                .contextMenu {
                    Button("Edit Operator…", systemImage: "person.text.rectangle") {
                        openWindow(id: OperatorWindow.id, value: group.id)
                    }
                    Button("New Conversation", systemImage: "plus.bubble") {
                        createConversation(operatorId: group.id)
                    }
                    Divider()
                    Button("Delete Operator…", systemImage: "trash", role: .destructive) {
                        pendingOperatorDeletion = group
                    }
                }
        }
    }

    private func unassignedSection(_ group: AgentSidebarGroup) -> some View {
        Section("Unassigned") {
            ForEach(group.timelines) { timeline in
                TimelineRow(conversation: timeline)
                    .tag(SidebarSelection.timeline(timeline.id))
            }
            .onDelete { offsets in deleteTimelines(offsets, from: group.timelines) }
        }
    }

    private func expansionBinding(for agentId: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedAgentIds.contains(agentId) },
            set: { isExpanded in
                if isExpanded { expandedAgentIds.insert(agentId) } else { expandedAgentIds.remove(agentId) }
            }
        )
    }

    private func createAgent() {
        guard let runtime else { return }
        do {
            let agent = try runtime.createAgent(modelContext: modelContext)
            expandedAgentIds.insert(agent.id)
            withAnimation { selection = .agent(agent.id) }
        } catch {
            creationError = Log.userFriendlyErrorMessage(for: error)
        }
    }

    private func createUnassignedTimeline() {
        createConversation(operatorId: nil)
    }

    private func createConversation(operatorId: UUID?) {
        guard let runtime else { return }
        Task {
            do {
                let conversation = try await runtime.createConversation(modelContext: modelContext, agentId: operatorId)
                if let operatorId { expandedAgentIds.insert(operatorId) }
                withAnimation { selection = .timeline(conversation.id) }
            } catch {
                creationError = Log.userFriendlyErrorMessage(for: error)
            }
        }
    }

    private func deleteOperator(_ id: UUID) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.deleteAgent(id: id, modelContext: modelContext)
                if selection == .agent(id) { selection = nil }
            } catch {
                creationError = Log.userFriendlyErrorMessage(for: error)
            }
        }
    }

    private func deleteTimelines(_ offsets: IndexSet, from timelines: [ConversationModel]) {
        for index in offsets {
            let conversation = timelines[index]
            if selection == .timeline(conversation.id) {
                selection = nil
            }
            let orphanedTerminalIds = WorkspaceAttachmentSupport.deleteConversation(conversation, modelContext: modelContext)
            if !orphanedTerminalIds.isEmpty, let runtime {
                Task {
                    for id in orphanedTerminalIds {
                        await runtime.terminalRegistry.terminate(id: id)
                    }
                }
            }
        }
    }
}

private struct TimelineRow: View {
    let conversation: ConversationModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.body)
                Text(conversation.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !conversation.allAttachedWorkspaceIds.isEmpty {
                let count = conversation.allAttachedWorkspaceIds.count
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(count == 1 ? "Has Workspace" : "Has \(count) Workspaces")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), \(conversation.timelineState.rawValue)")
    }

    private var dotColor: Color {
        switch conversation.timelineState {
        case .idle:
            .secondary.opacity(0.45)
        case .running:
            .blue
        case .tooling:
            .orange
        case .completed:
            .green
        case .blocked:
            .yellow
        case .waitingForWorkspace:
            .yellow
        case .failed:
            .red
        case .cancelled:
            .gray
        }
    }
}
