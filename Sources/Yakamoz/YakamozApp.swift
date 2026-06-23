import SwiftUI

@main
struct YakamozApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        Settings {
            Text("Provider settings")
        }
        .commandsRemoved()
    }
}
