import SwiftUI
import YakamozCore
import YakamozNetwork

/// The chat surface for a selected network Timeline (issue #10).
///
/// Reuses `ChatViewModel`, `MessageBubble`, `ComposerView`, and the existing tool
/// approval banner, but runs Turns through ``GnosticBackend`` instead of the local
/// runtime. It deliberately shows no inspector: network sessions carry no prompt/turn
/// telemetry, and the standalone Network inspector tab is issue #11.
///
/// Opening the view retains the Timeline as an open session, so a deadvertisement keeps
/// it visible as offline — with the composer disabled and the reason shown — rather than
/// dropping the conversation mid-read.
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
        guard case let .timeline(timeline)? = session.object(for: key) else { return nil }
        return timeline
    }

    private var ascendant: NetworkAscendant? {
        timeline.flatMap { session.catalog.ascendant(for: $0) }
    }

    private var availability: NetworkChatAvailability {
        guard let timeline else { return .blocked(reason: "This timeline is no longer on the network.") }
        return .resolve(
            connection: session.state,
            status: .of(timeline, isOffline: !session.isLive(key)),
            isArchived: timeline.isArchived
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let toolApprover {
                ToolApprovalBanner(approver: toolApprover)
            }

            if let viewModel {
                if let reason = availability.reason {
                    NetworkNoticeBanner(text: reason)
                    Divider()
                }
                transcript(viewModel)
                Divider()
                ComposerView(
                    text: $draft,
                    isSending: viewModel.isSending,
                    onSend: { send(viewModel) },
                    onCancel: { viewModel.cancel() },
                    focusToken: composerFocusToken,
                    isDisabled: availability != .ready,
                    disabledReason: availability.reason
                )
            } else {
                NetworkUnavailableView()
            }
        }
        .navigationTitle(timeline?.title ?? "Network Timeline")
        .navigationSubtitle(ascendant.map { "Network · \($0.name)" } ?? "Network")
        .toolbar {
            if let workspaceController, timeline != nil {
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
            session.openSession(key)
            buildViewModel()
        }
        .onDisappear {
            viewModel?.cancel()
        }
    }

    @ViewBuilder
    private func transcript(_ viewModel: ChatViewModel) -> some View {
        if viewModel.transcript.isEmpty {
            ContentUnavailableView(
                ascendant.map { "Message \($0.name)" } ?? "Start a Network Turn",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Turns run remotely on the Ascendant's Node. Messages sent before this window opened aren't shown.")
            )
            .frame(maxHeight: .infinity)
        } else {
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
    }

    private func buildViewModel() {
        viewModel?.cancel()
        guard let timeline else {
            viewModel = nil
            return
        }
        draft = ""
        viewModel = ChatViewModel(
            timelineId: key.objectID,
            runner: backend.scoped(to: key),
            modelName: ascendant?.name ?? timeline.provenance.providerID
        )
    }

    private func send(_ viewModel: ChatViewModel) {
        guard availability == .ready else { return }
        let text = draft
        draft = ""
        viewModel.send(text)
        composerFocusToken += 1
    }
}
