import SwiftUI
import YakamozCore

/// YAK-MON-4: Monad-mode sidebar. Lists server agent instances/templates (from the
/// selected `MonadProfile`) and, per selected agent, its server timelines — all fetched
/// on demand through `MonadAgentListing`/`BackendTimelineListing`, never cached as local
/// SwiftData records. Refreshes whenever the profile changes or the view (re)appears
/// (e.g. switching into Monad mode).
struct MonadSidebarView: View {
    @Binding var selection: MonadSidebarSelection?
    let profile: MonadProfile?
    @Environment(\.secretStore) private var secretStore

    @State private var loadState: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded([MonadSidebarSection])
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle("Monad")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task(id: profile?.id) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading Monad agents…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't Load Monad Agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await load() }
                }
            }
        case let .loaded(sections):
            if sections.isEmpty {
                ContentUnavailableView(
                    "No Server Agents",
                    systemImage: "server.rack",
                    description: Text("This Monad server has no agent instances or templates yet.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.agents) { agent in
                                Label(agent.name, systemImage: agent.kind == .instance ? "person.crop.circle" : "doc.text")
                                    .tag(MonadSidebarSelection.agent(agent.id))
                            }
                        }
                    }
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
            async let instances = backend.listAgentInstances()
            async let templates = backend.listAgentTemplates()
            let sections = try MonadSidebarPresentation.sections(instances: await instances, templates: await templates)
            loadState = .loaded(sections)
        } catch {
            loadState = .failed(Log.userFriendlyErrorMessage(for: error))
        }
    }
}
