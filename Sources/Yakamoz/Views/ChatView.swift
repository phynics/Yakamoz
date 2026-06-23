import SwiftData
import SwiftUI
import YakamozCore

/// Owns the per-conversation `ChatViewModel`, built from the environment runtime and
/// `conversation.id` — the same `UUID` used as the PositronicKit `timelineId`
/// (see `ConversationCoordinator`).
struct ChatView: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.yakamozRuntime) private var runtime

    @State private var viewModel: ChatViewModel?
    @State private var inspectionViewModel: InspectionViewModel?
    @State private var draft = ""
    @State private var workspacePresentation: WorkspacePresentation?

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
                                onSelectTurn: { viewModel.selectedTurnIndex = $0 }
                            )
                        }
                    }
            }
            .onChange(of: viewModel.selectedTurnIndex) { _, newIndex in
                Task { await inspectionViewModel?.select(conversationId: conversation.id, turnIndex: newIndex) }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                onSelectTurn: { viewModel.selectedTurnIndex = $0 }
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
}
