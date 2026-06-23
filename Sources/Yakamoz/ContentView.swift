import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            Text("Conversations")
        } detail: {
            ContentUnavailableView("New Conversation", systemImage: "moon.stars")
        }
    }
}
