import Logging
import SwiftUI
import YakamozCore

/// Conversation-options menu exposing the per-conversation sidecar-directives toggle.
/// Changing the flag takes effect the next time `ChatView` rebuilds its `ChatViewModel`
/// (the `.task(id:)` below keys on this flag so the rebuild happens immediately).
struct SidecarControls: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Menu {
            Toggle(isOn: bind(\.sidecarDirectivesEnabled)) {
                Label("Sidecar Directives", systemImage: "sidebar.right")
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .help("Conversation options: sidecar directives")
        .accessibilityLabel("Conversation options")
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<ConversationModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { conversation[keyPath: keyPath] },
            set: {
                conversation[keyPath: keyPath] = $0
                do {
                    try modelContext.save()
                } catch {
                    Log.appError("failed to save conversation toggle setting", metadata: [
                        "conversationID": "\(conversation.id)",
                    ])
                }
            }
        )
    }
}
