import SwiftData
import SwiftUI
import YakamozCore

/// ATW-8: the agent detail surface — Chat (the agent's home timeline, lazily created),
/// Vault (NOTES.md + Memory browser), and Settings (identity, defaults, delete).
struct AgentDetailView: View {
    @Bindable var agent: AgentModel
    /// Cleared when the agent is deleted so `ContentView` falls back to the empty state.
    var onDeleted: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @State private var selectedTab: Tab = .chat
    @State private var homeTimeline: ConversationModel?
    @State private var homeTimelineError: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case vault = "Vault"
        case settings = "Settings"
        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)

            Divider().padding(.top, 8)

            content
        }
        .navigationTitle(agent.name)
        .task(id: agent.id) {
            await loadHomeTimeline()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .chat:
            if let homeTimeline {
                ChatView(conversation: homeTimeline)
            } else if let homeTimelineError {
                ContentUnavailableView(
                    "Couldn't Open Chat",
                    systemImage: "exclamationmark.triangle",
                    description: Text(homeTimelineError)
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .vault:
            AgentVaultView(agent: agent)
        case .settings:
            AgentSettingsView(agent: agent, onDeleted: onDeleted)
        }
    }

    private func loadHomeTimeline() async {
        guard let runtime else { return }
        do {
            homeTimeline = try await runtime.homeTimeline(for: agent.id, modelContext: modelContext)
        } catch {
            homeTimelineError = Log.userFriendlyErrorMessage(for: error)
        }
    }
}
