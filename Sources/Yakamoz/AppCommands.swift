import SwiftUI

/// App-wide UI intents raised by the macOS menu bar / keyboard shortcuts.
///
/// SwiftUI `.commands` live in the `Scene` and cannot reach into a specific view's
/// `@State`, so they publish coarse intents here instead. Views observe the matching
/// signal (a monotonically bumped token, so repeated presses re-fire) and act on it.
/// Kept in the app target with no `YakamozCore`/`PositronicKit` types, preserving the
/// app-target import boundary.
@MainActor
@Observable
final class UICoordinator {
    /// Bumped by Command-N. `ConversationListView` observes it to create a new chat.
    var newChatToken = 0
    /// Bumped by Command-I. `ChatView` observes it to toggle the inspector drawer.
    var toggleInspectorToken = 0
    /// Set by Command-1…6 to the requested inspector tab index (0-based), paired with a
    /// token so selecting the same tab twice still re-fires.
    var inspectorTabRequest: (index: Int, token: Int) = (0, 0)
    /// Bumped by Command-Return-adjacent flows / after a send to refocus the composer.
    var focusComposerToken = 0

    func requestNewChat() {
        newChatToken += 1
    }

    func requestToggleInspector() {
        toggleInspectorToken += 1
    }

    func requestInspectorTab(_ index: Int) {
        inspectorTabRequest = (index, inspectorTabRequest.token + 1)
    }

    func requestFocusComposer() {
        focusComposerToken += 1
    }

    /// `nonisolated` so the environment-key default (read by SwiftUI off the main actor in
    /// theory) can construct one without a main-actor hop. The stored token properties are
    /// trivially `Sendable`, so a freshly-built instance is safe to hand to the main actor.
    nonisolated init() {}
}

private struct UICoordinatorKey: EnvironmentKey {
    /// Shared fallback used only when a view renders outside the app's injected coordinator
    /// (e.g. a SwiftUI preview). The real one is injected by `YakamozApp`.
    static let defaultValue = UICoordinator()
}

extension EnvironmentValues {
    var uiCoordinator: UICoordinator {
        get { self[UICoordinatorKey.self] }
        set { self[UICoordinatorKey.self] = newValue }
    }
}

/// Menu-bar commands wired to `UICoordinator`. Added to the `WindowGroup` via `.commands`.
///
/// Shortcuts: Command-N (new chat), Command-I (toggle inspector), Command-1…6 (inspector
/// tabs). The six tab titles mirror `InspectorTab.allCases` order.
struct YakamozCommands: Commands {
    let coordinator: UICoordinator

    private static let inspectorTabTitles = ["Prompt", "Sent", "Journal", "Response", "Tools", "Workspace"]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { coordinator.requestNewChat() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Inspector") {
            Button("Toggle Inspector") { coordinator.requestToggleInspector() }
                .keyboardShortcut("i", modifiers: .command)

            Divider()

            ForEach(Array(Self.inspectorTabTitles.enumerated()), id: \.offset) { index, title in
                Button(title) { coordinator.requestInspectorTab(index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}
