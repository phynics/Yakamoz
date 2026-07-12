import SwiftUI
import YakamozCore

/// YAK-MON-4: Monad-mode detail pane. For a selected server agent, lists its server
/// timelines (fetched on demand, never cached locally). For a selected timeline, shows a
/// minimal summary — wiring Monad-mode chat streaming into a full `ChatView`-equivalent is
/// later ticket's job; local `ChatView` is built around `ConversationModel`/SwiftData and
/// isn't reusable here.
struct MonadAgentDetailView: View {
    let agentId: UUID
    let profile: MonadProfile?
    @Binding var selection: MonadSidebarSelection?
    @Environment(\.secretStore) private var secretStore

    @State private var loadState: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded([BackendTimelineSummary])
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle("Agent Timelines")
            .task(id: "\(agentId)-\(profile?.id.uuidString ?? "")") {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading timelines…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't Load Timelines", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await load() }
                }
            }
        case let .loaded(timelines):
            if timelines.isEmpty {
                ContentUnavailableView(
                    "No Timelines",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This agent has no server timelines yet.")
                )
            } else {
                List(timelines) { timeline in
                    Button {
                        selection = .timeline(timeline.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timeline.title).font(.body)
                            Text(timeline.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard let profile else {
            loadState = .loaded([])
            return
        }
        loadState = .loading
        do {
            guard let secretStore else {
                loadState = .failed("No secret store available.")
                return
            }
            let backend = try MonadYakamozBackend(profile: profile, secrets: secretStore)
            let timelines = try await backend.listTimelines(forAgent: agentId)
            loadState = .loaded(timelines)
        } catch {
            loadState = .failed(Log.userFriendlyErrorMessage(for: error))
        }
    }
}

/// YAK-MON-6: Monad-mode timeline detail with workspace attachment UI. Shows the
/// timeline summary, attached workspace chips (fetched from the server), an "Attach
/// Folder" button that opens `NSOpenPanel`, and detach buttons per chip. Terminal
/// workspaces are shown as unavailable. The server is authoritative — workspace
/// membership is always fetched from the server, never cached locally.
struct MonadTimelineSummaryView: View {
    let timelineId: UUID
    let profile: MonadProfile?
    @Environment(\.secretStore) private var secretStore

    @State private var viewModel: MonadWorkspaceViewModel?

    private var taskID: String {
        "\(timelineId)-\(profile?.id.uuidString ?? "")"
    }

    var body: some View {
        Group {
            if let viewModel {
                content(for: viewModel)
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
                return
            }
            let vm = MonadWorkspaceViewModel(
                timelineId: timelineId,
                profile: profile,
                secrets: secretStore
            )
            viewModel = vm
            await vm.load()
        }
        .onDisappear {
            Task { await viewModel?.cleanup() }
        }
    }

    @ViewBuilder
    private func content(for vm: MonadWorkspaceViewModel) -> some View {
        switch vm.loadState {
        case .loading:
            ProgressView("Loading timeline…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't Load Timeline", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await vm.load() }
                }
            }
        case .loaded:
            if let summary = vm.timelineSummary {
                loadedContent(summary: summary, vm: vm)
            } else {
                ContentUnavailableView(
                    "Timeline Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This timeline no longer exists on the server.")
                )
            }
        }
    }

    @ViewBuilder
    private func loadedContent(summary: BackendTimelineSummary, vm: MonadWorkspaceViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.title2)
                Text("ID: \(summary.id.uuidString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Created: \(summary.createdAt.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            workspaceSection(vm: vm)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func workspaceSection(vm: MonadWorkspaceViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Workspaces", systemImage: "folder.badge.plus")
                    .font(.headline)
                Spacer()
                if vm.isAttaching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = vm.actionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if vm.attachedWorkspaces.isEmpty {
                Text("No workspaces attached to this timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowingChipsLayout(spacing: 6) {
                    ForEach(vm.attachedWorkspaces) { workspace in
                        workspaceChip(workspace, vm: vm)
                    }
                }
            }

            Button {
                pickFolder(vm: vm)
            } label: {
                Label("Attach Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(vm.isAttaching)
            .accessibilityLabel("Attach a folder workspace to this timeline")

            Menu {
                Button {
                    pickFolder(vm: vm)
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
                .disabled(vm.isAttaching)

                Divider()

                Label("Terminal (unavailable in Monad mode)", systemImage: "terminal")
                    .foregroundStyle(.secondary)
            } label: {
                Label("Add Workspace", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add workspace options")
        }
    }

    @ViewBuilder
    private func workspaceChip(_ workspace: MonadWorkspacePresentation, vm: MonadWorkspaceViewModel) -> some View {
        switch workspace.availability {
        case .available:
            HStack(spacing: 4) {
                Label(workspace.displayName, systemImage: "folder.fill")
                    .font(.caption)
                    .lineLimit(1)
                Button {
                    Task { await vm.detachWorkspace(workspace.id) }
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

/// Simple horizontal-wrapping chip layout for workspace chips.
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
