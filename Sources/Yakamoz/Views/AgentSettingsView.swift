import SwiftData
import SwiftUI
import YakamozCore

/// ATW-8: Settings tab — name, instructions, default model, default tools, and delete.
struct AgentSettingsView: View {
    @Bindable var agent: AgentModel
    var onDeleted: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @State private var isDeleteConfirmationPresented = false
    @State private var deleteError: String?

    private var availableTools: [ConversationToolOption] {
        ConversationToolSupport.toolOptions(hasWorkspace: true, hasTerminal: true)
    }

    private var selectedDefaultTools: Set<String> {
        Set(agent.defaultEnabledToolIds ?? [])
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $agent.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $agent.instructions)
                        .font(.callout)
                        .frame(minHeight: 120)
                        .border(.quaternary)
                }
            }

            Section("Defaults") {
                TextField("Default Model", text: Binding(
                    get: { agent.defaultModel ?? "" },
                    set: { agent.defaultModel = $0.isEmpty ? nil : $0 }
                ))
                ForEach(availableTools) { tool in
                    Toggle(tool.title, isOn: Binding(
                        get: { selectedDefaultTools.contains(tool.id) },
                        set: { toggleDefaultTool(tool.id, isOn: $0) }
                    ))
                }
            }

            Section {
                Button("Delete Agent", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: agent.name) { _, _ in save() }
        .onChange(of: agent.instructions) { _, _ in save() }
        .onChange(of: agent.defaultModel) { _, _ in save() }
        .confirmationDialog(
            "Delete \(agent.name)?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteAgent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the agent's home timeline and vault. Timelines it merely operated become unassigned.")
        }
        .alert(
            "Couldn't Delete Agent",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func toggleDefaultTool(_ id: String, isOn: Bool) {
        var selected = selectedDefaultTools
        if isOn { selected.insert(id) } else { selected.remove(id) }
        agent.defaultEnabledToolIds = selected.isEmpty ? nil : Array(selected).sorted()
        save()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save agent settings", metadata: ["agentID": "\(agent.id)"])
        }
    }

    private func deleteAgent() {
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
