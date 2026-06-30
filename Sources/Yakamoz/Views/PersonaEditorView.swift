import Logging
import SwiftData
import SwiftUI
import YakamozCore

/// Toolbar persona control for a conversation: a menu that lists the four built-in personas
/// and any custom `PersonaModel`s, plus an editor sheet to create/rename a custom persona.
///
/// Selecting a persona writes its stable slug (built-in id or the custom row's UUID string)
/// to `conversation.personaSlug`; `ChatView` resolves that slug to the system instructions it
/// hands `makeChatViewModel`.
struct PersonaPicker: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Query private var customPersonas: [PersonaModel]

    @State private var isEditing = false
    @State private var editingPersona: PersonaModel?

    private var selectedName: String {
        guard let slug = conversation.personaSlug else { return "Default" }
        if let builtIn = PersonaCatalog.builtIn(id: slug) { return builtIn.name }
        if let custom = customPersonas.first(where: { $0.id.uuidString == slug }) { return custom.name }
        return "Default"
    }

    var body: some View {
        Menu {
            Button("Default") { conversation.personaSlug = nil }

            Section("Built-in") {
                ForEach(PersonaCatalog.builtIns) { persona in
                    Button(persona.name) { conversation.personaSlug = persona.id }
                }
            }

            if !customPersonas.isEmpty {
                Section("Custom") {
                    ForEach(customPersonas) { persona in
                        Button(persona.name) { conversation.personaSlug = persona.id.uuidString }
                    }
                }
            }

            Divider()
            Button {
                editingPersona = nil
                isEditing = true
            } label: {
                Label("New Persona…", systemImage: "plus")
            }
            if let editing = currentCustomPersona {
                Button {
                    editingPersona = editing
                    isEditing = true
                } label: {
                    Label("Edit “\(editing.name)”…", systemImage: "pencil")
                }
            }
        } label: {
            Label(selectedName, systemImage: "person.crop.circle")
                .font(.caption)
                .lineLimit(1)
        }
        .help("Choose or edit the conversation persona")
        .accessibilityLabel("Persona: \(selectedName)")
        .sheet(isPresented: $isEditing) {
            PersonaEditorView(persona: editingPersona) { saved in
                conversation.personaSlug = saved.id.uuidString
            }
        }
    }

    private var currentCustomPersona: PersonaModel? {
        guard let slug = conversation.personaSlug else { return nil }
        return customPersonas.first { $0.id.uuidString == slug }
    }
}

/// Create/edit sheet for a custom `PersonaModel`. On save, inserts (or updates) the row and
/// calls `onSave` with the persisted model so the caller can select it.
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
            Text(persona == nil ? "New Persona" : "Edit Persona")
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
        let model: PersonaModel
        if let persona {
            persona.name = trimmedName
            persona.systemInstructions = instructions
            model = persona
        } else {
            model = PersonaModel(name: trimmedName, systemInstructions: instructions, builtIn: false)
            modelContext.insert(model)
        }
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save persona", metadata: [
                "personaID": "\(model.id)",
            ])
        }
        onSave(model)
        dismiss()
    }
}
