import SwiftData
import SwiftUI
import YakamozCore

/// Toolbar operator control for a conversation.
struct PersonaPicker: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Query private var agents: [AgentModel]
    @State private var swapError: String?

    private var selectedName: String {
        guard let id = conversation.agentId else { return "Unassigned" }
        return agents.first(where: { $0.id == id })?.name ?? "Unassigned"
    }

    var body: some View {
        Menu {
            Button("Unassigned") { setOperator(nil) }
            ForEach(agents) { agent in
                Button(agent.name) { setOperator(agent.id) }
            }
        } label: {
            Label(selectedName, systemImage: "person.crop.circle")
                .font(.caption)
                .lineLimit(1)
        }
        .help("Choose the timeline operator")
        .accessibilityLabel("Operator: \(selectedName)")
        .disabled(conversation.isHomeTimeline)
        .alert("Couldn't Change Operator", isPresented: Binding(
            get: { swapError != nil },
            set: { if !$0 { swapError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(swapError ?? "") }
    }

    private func setOperator(_ agentId: UUID?) {
        guard let runtime else { return }
        Task {
            do { try await runtime.setOperator(modelContext: modelContext, conversationId: conversation.id, agentId: agentId) }
            catch { swapError = error.localizedDescription }
        }
    }
}
