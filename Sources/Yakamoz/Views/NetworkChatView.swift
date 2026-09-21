import SwiftUI
import YakamozCore
import YakamozNetwork

/// The chat surface for a selected network Timeline (issue #10).
///
/// Reuses `ChatViewModel`, `MessageBubble`, `ComposerView`, and the existing tool
/// approval banner, but runs Turns through ``GnosticBackend`` instead of the local
/// runtime. It deliberately shows no inspector: network sessions carry no prompt/turn
/// telemetry, and the standalone Network inspector tab is issue #11.
struct NetworkChatView: View {
    let key: NetworkObjectKey
    let session: NetworkClientSession
    let backend: GnosticBackend

    @Environment(\.toolApprover) private var toolApprover
    @Environment(\.networkWorkspaceController) private var workspaceController

    @State private var viewModel: ChatViewModel?
    @State private var draft = ""
    @State private var composerFocusToken = 0

    private var timeline: NetworkTimelineRef? {
        guard case let .timeline(timeline)? = session.catalog.object(for: key) else { return nil }
        return timeline
    }

    var body: some View {
        VStack(spacing: 0) {
            if let toolApprover {
                ToolApprovalBanner(approver: toolApprover)
            }

            if let viewModel {
                transcript(viewModel)
                Divider()
                ComposerView(
                    text: $draft,
                    isSending: viewModel.isSending,
                    onSend: { send(viewModel) },
                    onCancel: { viewModel.cancel() },
                    focusToken: composerFocusToken
                )
            } else {
                ContentUnavailableView(
                    "Network Timeline Unavailable",
                    systemImage: "network.slash",
                    description: Text("This timeline is no longer advertised.")
                )
            }
        }
        .navigationTitle(timeline?.title ?? "Network Timeline")
        .toolbar {
            if let workspaceController {
                ToolbarItem(placement: .automatic) {
                    NetworkWorkspaceMenu(
                        timelineKey: key,
                        session: session,
                        controller: workspaceController
                    )
                }
            }
        }
        .task(id: key) {
            buildViewModelIfNeeded()
        }
        .onDisappear {
            viewModel?.cancel()
        }
    }

    private func transcript(_ viewModel: ChatViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.transcript) { item in
                    MessageBubble(
                        item: item,
                        isSelected: false,
                        onSelectTurn: { _ in },
                        onSelectPromptOption: { _, _ in },
                        onRetry: { viewModel.retryFailedTurn(errorId: $0) }
                    )
                    .id(item.id)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
    }

    private func buildViewModelIfNeeded() {
        viewModel?.cancel()
        guard timeline != nil else {
            viewModel = nil
            return
        }
        viewModel = ChatViewModel(
            timelineId: key.objectID,
            runner: backend.scoped(to: key),
            modelName: timeline?.provenance.providerID ?? "network"
        )
    }

    private func send(_ viewModel: ChatViewModel) {
        let text = draft
        draft = ""
        viewModel.send(text)
        composerFocusToken += 1
    }
}
