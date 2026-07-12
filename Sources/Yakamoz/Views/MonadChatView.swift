import SwiftUI
import YakamozCore

/// YAK-MON-7: Monad-mode chat view. Streams a server-side conversation through
/// `MonadChatViewModel` (which wraps `ChatViewModel` + `MonadYakamozBackend`),
/// renders the transcript with `MessageBubble`, and integrates workspace
/// attachment UI from `MonadWorkspaceViewModel`. Simpler than local `ChatView`:
/// no SwiftData, no inspector drawer, no sidecar/annotation wiring.
struct MonadChatView: View {
    let timelineId: UUID
    let profile: MonadProfile?
    @Environment(\.secretStore) private var secretStore

    @State private var viewModel: MonadChatViewModel?
    @State private var workspaceViewModel: MonadWorkspaceViewModel?
    @State private var draft = ""

    private var taskID: String {
        "\(timelineId)-\(profile?.id.uuidString ?? "")"
    }

    var body: some View {
        Group {
            if let viewModel {
                chatBody(viewModel: viewModel)
            } else if profile == nil {
                ContentUnavailableView(
                    "No Monad Profile",
                    systemImage: "server.rack",
                    description: Text("Select a Monad server profile to view this timeline.")
                )
            } else if secretStore == nil {
                ContentUnavailableView(
                    "No Secret Store",
                    systemImage: "lock.slash",
                    description: Text("The secret store is not available.")
                )
            } else {
                ProgressView("Loading timeline…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: taskID) {
            guard let profile, let secretStore else {
                viewModel = nil
                workspaceViewModel = nil
                return
            }
            do {
                let backend = try MonadYakamozBackend(profile: profile, secrets: secretStore)
                let chatVM = MonadChatViewModel(timelineId: timelineId, runner: backend)
                let wsVM = MonadWorkspaceViewModel(
                    timelineId: timelineId,
                    profile: profile,
                    secrets: secretStore
                )
                viewModel = chatVM
                workspaceViewModel = wsVM
                await wsVM.load()
            } catch {
                viewModel = nil
                workspaceViewModel = nil
            }
        }
        .onDisappear {
            viewModel?.cancel()
            Task { await workspaceViewModel?.cleanup() }
        }
    }

    @ViewBuilder
    private func chatBody(viewModel: MonadChatViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.chatViewModel.transcript) { item in
                            MessageBubble(
                                item: item,
                                isSelected: isSelected(item, viewModel: viewModel),
                                onSelectTurn: { viewModel.chatViewModel.selectTurn($0) },
                                onSelectPromptOption: { _, _ in },
                                onRetry: { viewModel.retryFailedTurn(errorId: $0) }
                            )
                            .id(item.id)
                        }
                        Color.clear
                            .frame(height: 0)
                            .id("monad-scroll-bottom")
                    }
                    .padding()
                }
                .onChange(of: viewModel.chatViewModel.transcript.last?.id) { _, _ in
                    proxy.scrollTo("monad-scroll-bottom", anchor: .bottom)
                }
                .onChange(of: viewModel.chatViewModel.transcript.count) { _, _ in
                    proxy.scrollTo("monad-scroll-bottom", anchor: .bottom)
                }
            }

            Divider()

            if let ws = workspaceViewModel {
                workspaceBar(vm: ws)
            }

            if let error = viewModel.chatViewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }

            ComposerView(
                text: $draft,
                isSending: viewModel.chatViewModel.isSending,
                onSend: { send(viewModel: viewModel) },
                onCancel: { viewModel.cancel() }
            )
        }
        .navigationTitle(workspaceViewModel?.timelineSummary?.title ?? "Timeline")
    }

    private func isSelected(_ item: TranscriptItem, viewModel: MonadChatViewModel) -> Bool {
        guard case let .assistant(_, turn) = item else { return false }
        return viewModel.chatViewModel.selectedTurnIndex == turn.turnIndex
    }

    private func send(viewModel: MonadChatViewModel) {
        let text = draft
        draft = ""
        viewModel.send(text)
    }

    @ViewBuilder
    private func workspaceBar(vm: MonadWorkspaceViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Workspaces", systemImage: "folder.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.isAttaching {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    pickFolder(vm: vm)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(vm.isAttaching)
                .help("Attach a folder workspace")
            }

            if let error = vm.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !vm.attachedWorkspaces.isEmpty {
                FlowingWorkspaceChips(workspaces: vm.attachedWorkspaces) { workspaceId in
                    Task { await vm.detachWorkspace(workspaceId) }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func pickFolder(vm: MonadWorkspaceViewModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Choose a folder to attach as a workspace to this timeline."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await vm.attachFolder(at: url) }
    }
}

private struct FlowingWorkspaceChips: View {
    let workspaces: [MonadWorkspacePresentation]
    let onDetach: (UUID) -> Void

    var body: some View {
        FlowingChipsLayout(spacing: 6) {
            ForEach(workspaces) { workspace in
                chip(workspace)
            }
        }
    }

    @ViewBuilder
    private func chip(_ workspace: MonadWorkspacePresentation) -> some View {
        switch workspace.availability {
        case .available:
            HStack(spacing: 4) {
                Label(workspace.displayName, systemImage: "folder.fill")
                    .font(.caption)
                    .lineLimit(1)
                Button {
                    onDetach(workspace.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Detach \(workspace.displayName)")
                .accessibilityLabel("Detach \(workspace.displayName)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

        case let .unavailable(reason):
            HStack(spacing: 4) {
                Label(workspace.displayName, systemImage: workspace.kind == .terminal ? "terminal" : "exclamationmark.triangle")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quinary, in: Capsule())
            .help(reason)
            .accessibilityLabel("\(workspace.displayName) — unavailable: \(reason)")
        }
    }
}

private struct FlowingChipsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > maxWidth && currentLineWidth > 0 {
                totalHeight += currentLineHeight + spacing
                currentLineWidth = 0
                currentLineHeight = 0
            }
            currentLineWidth += size.width + spacing
            currentLineHeight = max(currentLineHeight, size.height)
        }
        totalHeight += currentLineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
