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

/// Minimal placeholder detail for a selected Monad-mode timeline: id/title summary only.
/// Full Monad-mode chat streaming is a later ticket.
struct MonadTimelineSummaryView: View {
    let timelineId: UUID
    let profile: MonadProfile?
    @Environment(\.secretStore) private var secretStore

    @State private var summary: BackendTimelineSummary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.title).font(.title2)
                    Text("ID: \(summary.id.uuidString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Created: \(summary.createdAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Full Monad-mode chat is not yet wired up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Timeline", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView("Loading timeline…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(timelineId)-\(profile?.id.uuidString ?? "")") {
            await load()
        }
    }

    private func load() async {
        guard let profile, let secretStore else {
            errorMessage = "No Monad profile selected."
            return
        }
        do {
            let backend = try MonadYakamozBackend(profile: profile, secrets: secretStore)
            summary = try await backend.loadTimeline(id: timelineId)
            if summary == nil {
                errorMessage = "Timeline not found."
            }
        } catch {
            errorMessage = Log.userFriendlyErrorMessage(for: error)
        }
    }
}
