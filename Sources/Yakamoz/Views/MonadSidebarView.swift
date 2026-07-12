import SwiftUI
import YakamozCore

/// YAK-MON-4: Monad-mode sidebar. Lists server agent instances/templates (from the
/// selected `MonadProfile`) and, per selected agent, its server timelines — all fetched
/// on demand through `MonadAgentListing`/`BackendTimelineListing`, never cached as local
/// SwiftData records. Refreshes whenever the profile changes or the view (re)appears
/// (e.g. switching into Monad mode).
///
/// YAK-MON-11: also lists ordinary server timelines (via `BackendTimelineListing.listTimelines()`)
/// in a dedicated "Timelines" section, with a "New Timeline" toolbar button that prompts for
/// a title and creates a server timeline through `MonadTimelineBrowsingViewModel`. After
/// creation the list refreshes and the new timeline is selected, routing `ContentView` to
/// `MonadChatView`.
struct MonadSidebarView: View {
    @Binding var selection: MonadSidebarSelection?
    let profile: MonadProfile?
    @Environment(\.secretStore) private var secretStore

    @State private var loadState: LoadState = .loading
    @State private var timelineVM: MonadTimelineBrowsingViewModel?
    @State private var showingCreateTimeline = false
    @State private var newTimelineTitle = ""

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
                        Task {
                            await load()
                            await timelineVM?.load()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem {
                    Button {
                        showingCreateTimeline = true
                    } label: {
                        Label("New Timeline", systemImage: "plus")
                    }
                    .disabled(timelineVM == nil)
                    .accessibilityLabel("New Timeline")
                }
            }
            .task(id: profile?.id) {
                await load()
                await loadTimelines()
            }
            .alert("New Timeline", isPresented: $showingCreateTimeline) {
                TextField("Timeline title", text: $newTimelineTitle)
                Button("Create") {
                    let title = newTimelineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    newTimelineTitle = ""
                    guard !title.isEmpty else { return }
                    Task {
                        if let created = await timelineVM?.createTimeline(title: title) {
                            selection = .timeline(created.id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    newTimelineTitle = ""
                }
            } message: {
                Text("Enter a title for the new server timeline.")
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
                    Task {
                        await load()
                        await loadTimelines()
                    }
                }
            }
        case let .loaded(sections):
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.agents) { agent in
                            Label(agent.name, systemImage: agent.kind == .instance ? "person.crop.circle" : "doc.text")
                                .tag(MonadSidebarSelection.agent(agent.id))
                        }
                    }
                }
                timelinesSection
            }
        }
    }

    @ViewBuilder
    private var timelinesSection: some View {
        Section("Timelines") {
            if let vm = timelineVM {
                switch vm.loadState {
                case .loading:
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading timelines…")
                            .foregroundStyle(.secondary)
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await vm.load() }
                        }
                        .buttonStyle(.borderless)
                    }
                case .loaded:
                    if vm.isCreating {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = vm.actionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if vm.timelines.isEmpty && !vm.isCreating {
                        Text("No timelines")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.timelines) { timeline in
                            Label(timeline.title, systemImage: "bubble.left.and.bubble.right")
                                .tag(MonadSidebarSelection.timeline(timeline.id))
                        }
                    }
                }
            } else {
                Text("Select a Monad profile to browse timelines")
                    .foregroundStyle(.secondary)
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

    private func loadTimelines() async {
        guard let profile, let secretStore else {
            timelineVM = nil
            return
        }
        let vm = MonadTimelineBrowsingViewModel(profile: profile, secrets: secretStore)
        timelineVM = vm
        await vm.load()
    }
}
