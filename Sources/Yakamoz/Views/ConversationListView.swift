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
        // The `@Query`-driven list reorders whenever a new conversation is inserted (it's
        // sorted by `createdAt` descending, so a new row always lands at the top). Without an
        // explicit animation, that reorder plus the subsequent selection change reads as a
        // jarring snap (YAK-21); this makes the insertion/reorder itself animate smoothly,
        // matching the `withAnimation` around the selection assignment below.
        .animation(.default, value: conversations.map(\.id))
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
                // The new row must exist in `conversations` (the `@Query`-driven source of
                // truth for the List) before selection is set — setting it any earlier lets
                // SwiftUI resolve selection against a list that hasn't reordered/inserted yet,
                // producing a visible select-then-reorder double movement (YAK-21). `@Query`
                // republishes synchronously on save, so by the time this `Task` resumes after
                // `createConversation`'s insert+save, the row is already present; animate the
                // insertion and selection together so it reads as one smooth change rather than
                // an unanimated snap.
                withAnimation {
                    selection = conversation
                }
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
