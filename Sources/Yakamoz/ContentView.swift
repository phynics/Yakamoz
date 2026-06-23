import SwiftUI
import YakamozCore

struct ContentView: View {
    @State private var selection: ConversationModel?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let selection {
                ChatView(conversation: selection)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
    }
}
