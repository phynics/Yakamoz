import SwiftData
import SwiftUI
import YakamozCore

/// Owns the per-conversation `ChatViewModel`, built from the environment runtime and
/// `conversation.id` — the same `UUID` used as the PositronicKit `timelineId`
/// (see `ConversationCoordinator`).
struct ChatView: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @State private var viewModel: ChatViewModel?
    @State private var inspectionViewModel: InspectionViewModel?
    @State private var draft = ""
    @State private var workspacePresentation: WorkspacePresentation?
    @State private var workspacePromptId: UUID?
    @State private var dismissedWorkspacePromptConversationId: UUID?

    @SceneStorage("inspector.isOpen") private var isInspectorOpen = false

    @Query private var workspaces: [WorkspaceModel]

    private var attachedWorkspace: WorkspaceModel? {
        guard let workspaceId = conversation.workspaceId else { return nil }
        return workspaces.first { $0.id == workspaceId }
    }

    private var workspaceRoot: URL? {
        attachedWorkspace.map { URL(fileURLWithPath: $0.folderPath) }
    }

    var body: some View {
        Group {
            if let viewModel {
                chatBody(viewModel: viewModel)
            } else {
                ContentUnavailableView(
                    "Runtime Unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .navigationTitle(conversation.title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.snappy) { isInspectorOpen.toggle() }
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                }
                .help(isInspectorOpen ? "Hide inspector" : "Show inspector")
                .accessibilityLabel(isInspectorOpen ? "Hide inspector" : "Show inspector")
            }

            ToolbarItem(placement: .automatic) {
                WorkspacePicker(conversation: conversation)
            }
        }
        .task(id: conversation.id) {
            await buildViewModelIfNeeded()
        }
        .task(id: conversation.workspaceId) {
            await refreshWorkspacePresentation()
        }
    }

    private func chatBody(viewModel: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                conversationStack(viewModel: viewModel)
                    .overlay(alignment: .bottom) {
                        if let inspectionViewModel {
                            InspectorDrawer(
                                viewModel: inspectionViewModel,
                                detailHeight: proxy.size.height,
                                selectedTurnState: viewModel.selectedTurnState,
                                workspacePresentation: workspacePresentation,
                                onRefreshWorkspace: { Task { await refreshWorkspacePresentation() } },
                                isOpen: $isInspectorOpen,
                                onSelectTurn: { viewModel.selectedTurnIndex = $0 }
                            )
                        }
                    }
            }
            .onChange(of: viewModel.selectedTurnIndex) { _, newIndex in
                Task { await inspectionViewModel?.select(conversationId: conversation.id, turnIndex: newIndex) }
            }

            Divider()

            ComposerView(
                text: $draft,
                isSending: viewModel.isSending,
                onSend: { send(viewModel: viewModel) },
                onCancel: { viewModel.cancel() }
            )
        }
    }

    private func conversationStack(viewModel: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.transcript) { item in
                            MessageBubble(
                                item: item,
                                isSelected: isSelected(item, viewModel: viewModel),
                                onSelectTurn: { viewModel.selectedTurnIndex = $0 },
                                onSelectPromptOption: handlePromptSelection
                            )
                            .id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.transcript.last?.id) { _, newId in
                    guard let newId else { return }
                    withAnimation {
                        proxy.scrollTo(newId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func isSelected(_ item: TranscriptItem, viewModel: ChatViewModel) -> Bool {
        guard case let .assistant(_, turn) = item else { return false }
        return viewModel.selectedTurnIndex == turn.turnIndex
    }

    private func send(viewModel: ChatViewModel) {
        let text = draft
        draft = ""
        viewModel.send(text)
    }

    private func buildViewModelIfNeeded() async {
        guard let runtime else { return }
        workspacePromptId = nil
        let chat = await runtime.makeChatViewModel(
            timelineId: conversation.id,
            enabledToolIds: conversation.enabledToolIds,
            workspaceRoot: workspaceRoot
        )
        let inspection = await runtime.makeInspectionViewModel()
        viewModel = chat
        inspectionViewModel = inspection
        await inspection.select(conversationId: conversation.id, turnIndex: chat.selectedTurnIndex)
        await refreshWorkspacePresentation()
        offerWorkspacePromptIfNeeded(in: chat)
    }

    /// Rebuilds the Workspace-tab presentation from the conversation's attached folder
    /// workspace (or clears it when none is attached). Runs on conversation open and
    /// whenever `conversation.workspaceId` changes.
    private func refreshWorkspacePresentation() async {
        guard let runtime, let workspace = attachedWorkspace else {
            workspacePresentation = nil
            return
        }
        // Extract Sendable values on the MainActor; never send the @Model across the boundary.
        let folderPath = workspace.folderPath
        let displayName = workspace.displayName
        workspacePresentation = await runtime.makeWorkspacePresentation(folderPath: folderPath, displayName: displayName)
    }

    private func offerWorkspacePromptIfNeeded(in viewModel: ChatViewModel) {
        guard conversation.workspaceId == nil else { return }
        guard dismissedWorkspacePromptConversationId != conversation.id else { return }
        guard workspacePromptId == nil else { return }
        guard viewModel.transcript.allSatisfy({ item in
            if case .prompt = item { return true }
            return false
        }) else { return }

        workspacePromptId = viewModel.presentPrompt(ChatPrompt(
            title: "Attach a folder?",
            detail: "Use it as this chat's workspace.",
            options: [
                ChatPromptOption(id: "documents", title: "Documents", systemImage: "folder"),
                ChatPromptOption(id: "choose", title: "Choose Folder", systemImage: "folder.badge.plus"),
                ChatPromptOption(id: "skip", title: "Skip", systemImage: "xmark"),
            ]
        ))
    }

    private func handlePromptSelection(promptId: UUID, option: ChatPromptOption) {
        viewModel?.dismissTranscriptItem(id: promptId)
        if workspacePromptId == promptId {
            workspacePromptId = nil
            dismissedWorkspacePromptConversationId = conversation.id
        }

        switch option.id {
        case "documents":
            if let url = WorkspaceAttachmentSupport.defaultDocumentsURL {
                WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
                Task { await buildViewModelIfNeeded() }
            }
        case "choose":
            pickFolderForPrompt()
        default:
            break
        }
    }

    private func pickFolderForPrompt() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Choose a folder to use as this conversation's workspace."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
        Task { await buildViewModelIfNeeded() }
    }
}
