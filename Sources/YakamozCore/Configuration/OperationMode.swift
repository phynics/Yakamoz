import Foundation

/// The app-level runtime mode Yakamoz operates in.
///
/// - `local`: current behavior — SwiftData persistence with an embedded `YakamozRuntime`
///   driving PositronicKit directly in-process. This remains the default on a fresh install.
/// - `monad`: server-backed data from a selected `MonadProfile`. Conversations/timelines are
///   never cached locally in this mode (YAK-MON-1 scope): Yakamoz only remembers which mode
///   and profile were last active, as a launch default for new windows.
public enum OperationMode: String, Codable, Sendable, CaseIterable {
    case local
    case monad
}
