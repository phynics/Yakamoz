import SwiftData
import SwiftUI
import YakamozCore

/// Selecting an operator opens its home conversation in the same `ChatView` every other
/// conversation uses (docs/design/interaction-paradigm.md §3.2). The home conversation is
/// created lazily the first time it's opened. Profile and vault editing live in the
/// operator window (`OperatorWindow`), reached from the toolbar's operator menu or the
/// sidebar row's context menu.
struct OperatorHomeView: View {
    let agent: AgentModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @State private var homeConversation: ConversationModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let homeConversation, homeConversation.agentId == agent.id {
                ChatView(conversation: homeConversation)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't Open \(agent.name)",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: agent.id) {
            await loadHomeConversation()
        }
    }

    private func loadHomeConversation() async {
        guard let runtime else { return }
        loadError = nil
        do {
            homeConversation = try await runtime.homeTimeline(for: agent.id, modelContext: modelContext)
        } catch {
            loadError = Log.userFriendlyErrorMessage(for: error)
        }
    }
}
