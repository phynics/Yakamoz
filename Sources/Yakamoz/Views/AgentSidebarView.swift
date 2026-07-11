import SwiftData
import SwiftUI
import YakamozCore

/// ATW-8: the agents-centric sidebar. Top-level rows are agents (expanding one reveals its
/// operated non-home timelines, newest first); a trailing "Unassigned" group holds
/// timelines with no operator. Footer actions create a new agent or a new (unassigned)
/// timeline.
struct AgentSidebarView: View {
    @Binding var selection: SidebarSelection?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Environment(\.uiCoordinator) private var coordinator

    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]
    @Query(filter: ConversationListQuery.standardPredicate, sort: \ConversationModel.createdAt, order: .reverse)
    private var conversations: [ConversationModel]

    @State private var expandedAgentIds: Set<UUID> = []
    @State private var creationError: String?
    @State private var isWorkspaceLibraryPresented = false

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
        }
        .animation(.default, value: conversations.map(\.id))
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        createAgent()
                    } label: {
                        Label("New Agent", systemImage: "person.crop.circle.badge.plus")
                    }
                    Button {
                        createUnassignedTimeline()
                    } label: {
                        Label("New Timeline", systemImage: "plus.bubble")
                    }
                    Divider()
                    Button {
                        isWorkspaceLibraryPresented = true
                    } label: {
                        Label("Workspace Library", systemImage: "folder.badge.gearshape")
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
        .sheet(isPresented: $isWorkspaceLibraryPresented) {
            WorkspaceLibraryView()
        }
        .alert(
            "Couldn't Complete Action",
            isPresented: Binding(get: { creationError != nil }, set: { if !$0 { creationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(creationError ?? "")
        }
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
        guard let runtime else { return }
        Task {
            do {
                let conversation = try await runtime.createConversation(modelContext: modelContext)
                withAnimation { selection = .timeline(conversation.id) }
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
