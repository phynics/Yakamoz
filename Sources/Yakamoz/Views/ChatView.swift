import SwiftUI
import YakamozCore

/// Owns the per-conversation `ChatViewModel`, built from the environment runtime and
/// `conversation.id` — the same `UUID` used as the PositronicKit `timelineId`
/// (see `ConversationCoordinator`).
struct ChatView: View {
    let conversation: ConversationModel

    @Environment(\.yakamozRuntime) private var runtime

    @State private var viewModel: ChatViewModel?
    @State private var inspectionViewModel: InspectionViewModel?
    @State private var draft = ""

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
        .task(id: conversation.id) {
            await buildViewModelIfNeeded()
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
        let chat = await runtime.makeChatViewModel(timelineId: conversation.id)
        let inspection = await runtime.makeInspectionViewModel()
        viewModel = chat
        inspectionViewModel = inspection
        await inspection.select(conversationId: conversation.id, turnIndex: chat.selectedTurnIndex)
    }
}
