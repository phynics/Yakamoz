import SwiftData
import SwiftUI
import YakamozCore

// The conversation toolbar (docs/design/interaction-paradigm.md §3.3): every per-conversation
// setting lives here as a menu button whose label shows the current state, so the setup stays
// visible whichever turn the inspector is showing.

/// Assigns the conversation's operator and opens the operator window.
struct ConversationOperatorMenu: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]
    @State private var swapError: String?

    private var assigned: AgentModel? {
        conversation.agentId.flatMap { id in agents.first { $0.id == id } }
    }

    var body: some View {
        Menu {
            if conversation.isHomeTimeline {
                Text("A home conversation always belongs to its operator.")
            } else {
                Picker("Operator", selection: Binding(
                    get: { conversation.agentId },
                    set: { setOperator($0) }
                )) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(agents) { agent in
                        Text(agent.name).tag(UUID?.some(agent.id))
                    }
                }
                .pickerStyle(.inline)
            }
            if let assigned {
                Divider()
                Button("Edit \(assigned.name)…") {
                    openWindow(id: OperatorWindow.id, value: assigned.id)
                }
            }
        } label: {
            Label(assigned?.name ?? "Unassigned", systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
        }
        .help("The operator this conversation talks to")
        .accessibilityLabel("Operator: \(assigned?.name ?? "Unassigned")")
        .errorAlert("Couldn't Change Operator", message: $swapError)
    }

    private func setOperator(_ agentId: UUID?) {
        guard let runtime, agentId != conversation.agentId else { return }
        Task {
            do { try await runtime.setOperator(modelContext: modelContext, conversationId: conversation.id, agentId: agentId) }
            catch { swapError = Log.userFriendlyErrorMessage(for: error) }
        }
    }
}

/// Attaches, detaches, and manages the conversation's workspaces from one menu — the same
/// single-button pattern the network chat uses for Network workspaces.
struct ConversationWorkspacesMenu: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Query private var workspaces: [WorkspaceModel]
    @State private var isLibraryPresented = false

    private var attached: [WorkspaceModel] {
        WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: workspaces)
    }

    private var attachableLibraryWorkspaces: [WorkspaceModel] {
        let attachedIds = Set(attached.map(\.id))
        return workspaces
            .filter { !attachedIds.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        Menu {
            if !attached.isEmpty {
                Section("Attached") {
                    ForEach(attached) { workspace in
                        attachedItem(workspace)
                    }
                }
            }
            Section {
                Button("Attach Folder…", systemImage: "folder.badge.plus") {
                    WorkspaceActions.pickFolder(for: conversation, modelContext: modelContext)
                }
                Button("New Terminal…", systemImage: "terminal") {
                    WorkspaceActions.pickTerminalFolder(for: conversation, modelContext: modelContext)
                }
                if !attachableLibraryWorkspaces.isEmpty {
                    Menu("Attach from Library", systemImage: "books.vertical") {
                        ForEach(attachableLibraryWorkspaces) { workspace in
                            Button(workspace.displayName) {
                                WorkspaceAttachmentSupport.attachExisting(workspace, to: conversation, modelContext: modelContext)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Manage Library…") { isLibraryPresented = true }
        } label: {
            Label(label, systemImage: attached.isEmpty ? "folder" : "folder.fill")
                .labelStyle(.titleAndIcon)
        }
        .help("Folders and terminals this conversation's tools can use")
        .accessibilityLabel(label)
        .sheet(isPresented: $isLibraryPresented) {
            WorkspaceLibraryView()
        }
    }

    private var label: String {
        switch attached.count {
        case 0: "No Workspace"
        case 1: attached[0].displayName
        default: "\(attached.count) Workspaces"
        }
    }

    private func attachedItem(_ workspace: WorkspaceModel) -> some View {
        Menu(workspace.displayName, systemImage: workspace.kind == .terminal ? "terminal" : "folder") {
            Text(workspace.folderPath)
            if workspace.kind == .folder {
                Button("Create Terminal Here", systemImage: "terminal") {
                    WorkspaceAttachmentSupport.attachTerminal(to: conversation, fromFolder: workspace, modelContext: modelContext)
                }
            }
            Button("Detach", systemImage: "xmark.circle", role: .destructive) {
                detach(workspace)
            }
        }
    }

    private func detach(_ workspace: WorkspaceModel) {
        let prunedTerminalIds = WorkspaceAttachmentSupport.detachWorkspace(
            id: workspace.id,
            from: conversation,
            modelContext: modelContext
        )
        if let runtime, !prunedTerminalIds.isEmpty {
            Task {
                for id in prunedTerminalIds {
                    await runtime.terminalRegistry.terminate(id: id)
                }
            }
        }
    }
}

/// Toggles the conversation's tools (grouped by provenance) and its automatic titles and
/// sections (the sidecar directives).
struct ConversationToolsMenu: View {
    @Bindable var conversation: ConversationModel
    let availableTools: [ConversationToolOption]
    let enabledToolIds: Set<String>
    let onSetToolEnabled: (String, Bool) -> Void

    @Environment(\.modelContext) private var modelContext

    private static let groups: [(ConversationToolOption.Group, String)] = [
        (.builtIn, "Built-in"),
        (.workspace, "Workspace"),
        (.terminal, "Terminal"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.groups, id: \.0) { group, title in
                let tools = availableTools.filter { $0.group == group }
                if !tools.isEmpty {
                    Section(title) {
                        ForEach(tools) { tool in
                            Toggle(isOn: Binding(
                                get: { enabledToolIds.contains(tool.id) },
                                set: { onSetToolEnabled(tool.id, $0) }
                            )) {
                                Label(tool.title, systemImage: tool.systemImage)
                            }
                            // The last enabled tool can't be switched off.
                            .disabled(enabledToolIds == [tool.id])
                        }
                    }
                }
            }
            if !availableTools.contains(where: { $0.group == .workspace }) {
                Text("Attach a workspace to enable file tools.")
            }
            Divider()
            Toggle(isOn: Binding(
                get: { conversation.sidecarDirectivesEnabled },
                set: { setSidecarDirectives($0) }
            )) {
                Label("Automatic Titles & Sections", systemImage: "text.badge.star")
            }
        } label: {
            Label(enabledToolIds.count == 1 ? "1 Tool" : "\(enabledToolIds.count) Tools", systemImage: "wrench.and.screwdriver")
                .labelStyle(.titleAndIcon)
        }
        .help("Tools the operator may call in this conversation")
        .accessibilityLabel("Tools: \(enabledToolIds.count) enabled")
    }

    private func setSidecarDirectives(_ isEnabled: Bool) {
        conversation.sidecarDirectivesEnabled = isEnabled
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save conversation toggle setting", metadata: [
                "conversationID": "\(conversation.id)",
            ])
        }
    }
}

/// Folder pickers shared by the Workspaces menu and the empty-conversation state.
@MainActor
enum WorkspaceActions {
    static func pickFolder(for conversation: ConversationModel, modelContext: ModelContext) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Choose a folder to use as this conversation's workspace."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
    }

    static func pickTerminalFolder(for conversation: ConversationModel, modelContext: ModelContext) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Terminal"
        panel.message = """
        Choose a folder to be your terminal's starting directory.

        The terminal shell is NOT jailed to this folder; it can access any file on your system. \
        Each command is approval-gated unless you allow the terminal for the session.
        """

        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: conversation, modelContext: modelContext)
    }
}
