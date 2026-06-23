import SwiftUI
import YakamozCore

/// Conversation-options menu exposing the two Task 10 per-conversation toggles:
/// typed (structured) replies and bounded autonomous follow-up. Changing either flag takes
/// effect on the next time `ChatView` rebuilds its `ChatViewModel` (the `.task(id:)` below
/// keys on these flags so the rebuild happens immediately).
struct TypedReplyControls: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Menu {
            Toggle(isOn: bind(\.typedReplyEnabled)) {
                Label("Typed Replies", systemImage: "curlybraces")
            }
            Toggle(isOn: bind(\.autonomousFollowUpEnabled)) {
                Label("Autonomous Follow-up", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .help("Conversation options: typed replies and autonomous follow-up")
        .accessibilityLabel("Conversation options")
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<ConversationModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { conversation[keyPath: keyPath] },
            set: {
                conversation[keyPath: keyPath] = $0
                try? modelContext.save()
            }
        )
    }
}
