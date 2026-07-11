import Logging
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

/// Edit sheet for a migrated custom `PersonaModel`. New operators are persistent agents;
/// ATW-3 will replace this legacy editor with the agent-facing UI.
struct PersonaEditorView: View {
    let persona: PersonaModel?
    let onSave: (PersonaModel) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var instructions: String

    init(persona: PersonaModel?, onSave: @escaping (PersonaModel) -> Void) {
        self.persona = persona
        self.onSave = onSave
        _name = State(initialValue: persona?.name ?? "")
        _instructions = State(initialValue: persona?.systemInstructions ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Persona")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $instructions)
                        .font(.callout)
                        .frame(minHeight: 120)
                        .border(.quaternary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func save() {
        guard let persona else { return }
        persona.name = trimmedName
        persona.systemInstructions = instructions
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save persona", metadata: [
                "personaID": "\(persona.id)",
            ])
        }
        onSave(persona)
        dismiss()
    }
}
