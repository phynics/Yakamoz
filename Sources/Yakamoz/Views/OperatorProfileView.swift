import SwiftData
import SwiftUI
import YakamozCore

/// The operator window's Profile tab: name, instructions, and delete.
///
/// The model is app-wide (Settings and the conversation toolbar's model menu), so there is
/// no per-operator model or default-tool control here: those fields were persisted but never
/// applied (docs/design/interaction-paradigm.md, P4).
struct OperatorProfileView: View {
    @Bindable var agent: AgentModel
    var onDeleted: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @State private var isDeleteConfirmationPresented = false
    @State private var deleteError: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $agent.name)
            }

            Section {
                TextEditor(text: $agent.instructions)
                    .font(.callout)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Sent as the system prompt at the start of every turn with this operator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Delete Operator…", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            } footer: {
                Text("Deletes its home conversation and vault. Its other conversations become unassigned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: agent.name) { _, _ in save() }
        .onChange(of: agent.instructions) { _, _ in save() }
        .confirmationDialog(
            "Delete \(agent.name)?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteOperator() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the operator's home conversation and vault. Conversations it merely operated become unassigned.")
        }
        .errorAlert("Couldn't Delete Operator", message: $deleteError)
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save operator settings", metadata: ["agentID": "\(agent.id)"])
        }
    }

    private func deleteOperator() {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.deleteAgent(id: agent.id, modelContext: modelContext)
                onDeleted()
            } catch {
                deleteError = Log.userFriendlyErrorMessage(for: error)
            }
        }
    }
}
