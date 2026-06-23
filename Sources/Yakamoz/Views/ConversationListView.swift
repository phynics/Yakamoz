import SwiftData
import SwiftUI
import YakamozCore

/// Sidebar list of conversations. The "+" toolbar button creates a new
/// `ConversationModel` paired with a PositronicKit `Timeline` sharing the same id
/// (see `ConversationCoordinator`), so the engine can hydrate the same conversation
/// the moment the user sends a first message.
struct ConversationListView: View {
    @Binding var selection: ConversationModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Environment(\.uiCoordinator) private var coordinator

    @Query(sort: \ConversationModel.createdAt, order: .reverse)
    private var conversations: [ConversationModel]

    @State private var creationError: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                ConversationRow(conversation: conversation)
                    .tag(conversation)
            }
            .onDelete(perform: deleteConversations)
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button(action: createConversation) {
                    Label("New Conversation", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Conversation (⌘N)")
                .accessibilityLabel("New Conversation")
            }
        }
        .onChange(of: coordinator.newChatToken) { _, _ in
            createConversation()
        }
        .alert(
            "Couldn't Create Conversation",
            isPresented: Binding(
                get: { creationError != nil },
                set: { if !$0 { creationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(creationError ?? "")
        }
    }

    private func createConversation() {
        guard let runtime else { return }
        Task {
            do {
                let conversation = try await runtime.createConversation(modelContext: modelContext)
                selection = conversation
            } catch {
                creationError = error.localizedDescription
            }
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            if selection?.id == conversation.id {
                selection = nil
            }
            modelContext.delete(conversation)
        }
        try? modelContext.save()
    }
}

private struct ConversationRow: View {
    let conversation: ConversationModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.body)
                Text(conversation.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if conversation.personaId != nil {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has Persona")
            }
            if conversation.workspaceId != nil {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has Workspace")
            }
        }
        .padding(.vertical, 2)
    }
}
