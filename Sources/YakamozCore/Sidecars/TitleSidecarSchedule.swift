import Foundation

/// SID-1's until-first-then-interval cadence: the `title` directive rides every turn
/// while the conversation has no title, then only every `interval` turns once a title
/// exists — so an evolving conversation's title can refresh without paying for it
/// every turn.
public enum TitleSidecarSchedule {
    /// Default refresh interval (turns) once a title exists. Chosen as a sensible
    /// default per the ticket; not user-configurable in this iteration (YAGNI — add a
    /// setting if this proves wrong in practice).
    public static let defaultInterval = 5

    public static func isDue(hasTitle: Bool, turnsSinceLastTitle: Int, interval: Int = defaultInterval) -> Bool {
        guard hasTitle else { return true }
        return turnsSinceLastTitle >= interval
    }
}
