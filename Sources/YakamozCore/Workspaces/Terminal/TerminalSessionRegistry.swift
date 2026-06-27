import Foundation

/// Keeps `TerminalSession` instances alive for the lifetime of their owning workspace,
/// keyed by a stable workspace/terminal id (typically a timeline or terminal-tab id).
///
/// Sessions are lazily spawned on first access via `session(for:rootURL:)` and reused on
/// subsequent calls for the same id, so a terminal's shell process and scrollback survive
/// timeline switches in the UI. Callers are responsible for invoking `terminate(id:)` when a
/// session should be torn down (e.g. closing a terminal tab) and `terminateAll()` on app
/// shutdown or workspace teardown.
///
/// Also tracks a per-id "allow for session" approval flag (`allowForSession`/`isAllowed`),
/// used to back the terminal command-approval bypass: once a user allows a given terminal
/// session to run commands without per-command approval, that flag persists until the
/// session is terminated.
///
/// `TerminalSessionRegistry` is an actor, so all access is serialized and the type is safe to
/// share across concurrent callers.
public actor TerminalSessionRegistry {
    private var sessions: [UUID: TerminalSession] = [:]
    private var sessionAllow: Set<UUID> = []

    public init() {}

    /// Returns the existing session for `id`, or lazily spawns and stores a new one rooted at
    /// `rootURL` if none exists yet. Propagates any error encountered while spawning the shell.
    public func session(for id: UUID, rootURL: URL) async throws -> TerminalSession {
        if let existing = sessions[id] {
            return existing
        }
        let session = try await TerminalSession(rootURL: rootURL)
        sessions[id] = session
        return session
    }

    /// Terminates and removes the session for `id`, if one exists, and clears its allow flag.
    public func terminate(id: UUID) async {
        if let session = sessions[id] {
            await session.terminate()
            sessions.removeValue(forKey: id)
        }
        sessionAllow.remove(id)
    }

    /// Terminates every tracked session and clears all allow flags.
    public func terminateAll() async {
        for session in sessions.values {
            await session.terminate()
        }
        sessions.removeAll()
        sessionAllow.removeAll()
    }

    /// Marks `id` as allowed to run commands without per-command approval.
    public func allowForSession(_ id: UUID) {
        sessionAllow.insert(id)
    }

    /// Returns whether `id` has been marked as allowed via `allowForSession`.
    public func isAllowed(_ id: UUID) -> Bool {
        sessionAllow.contains(id)
    }
}
