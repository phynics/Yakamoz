import SwiftUI
import YakamozCore

/// ATW-8: Vault tab — editable `NOTES.md`, plus a read-only `Memory/` note listing with
/// rendered `[[wiki-link]]` text.
struct AgentVaultView: View {
    let agent: AgentModel

    @State private var notes: String = ""
    @State private var memoryNotes: [VaultMemoryNote] = []
    @State private var saveError: String?

    var body: some View {
        HSplitView {
            notesEditor
                .frame(minWidth: 280)
            memoryList
                .frame(minWidth: 240)
        }
        .task(id: agent.id) {
            reload()
        }
        .errorAlert("Couldn't Save Notes", message: $saveError)
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES.md")
                .font(.headline)
                .padding([.horizontal, .top], 12)
            TextEditor(text: $notes)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .onChange(of: notes) { _, newValue in
                    save(newValue)
                }
            Spacer(minLength: 0)
        }
    }

    private var memoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory")
                .font(.headline)
                .padding([.horizontal, .top], 12)
            if memoryNotes.isEmpty {
                ContentUnavailableView(
                    "No Memory Notes",
                    systemImage: "note.text",
                    description: Text("Notes the agent saves under Memory/ will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(memoryNotes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.body.weight(.medium))
                        renderedPreview(note.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func renderedPreview(_ text: String) -> Text {
        AgentVaultBrowsing.renderWikiLinks(text).reduce(Text("")) { partial, segment in
            switch segment {
            case let .text(string):
                Text("\(partial)\(string)")
            case let .wikiLink(link):
                Text("\(partial)\(Text(link).bold().foregroundStyle(.tint))")
            }
        }
    }

    private func reload() {
        notes = AgentVaultBrowsing.readNotes(agent: agent)
        memoryNotes = AgentVaultBrowsing.listMemoryNotes(agent: agent)
    }

    private func save(_ contents: String) {
        do {
            try AgentVaultBrowsing.writeNotes(agent: agent, contents: contents)
        } catch {
            saveError = Log.userFriendlyErrorMessage(for: error)
        }
    }
}
