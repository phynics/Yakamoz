import Foundation
import PKShared

/// Errors produced by terminal-workspace primitives (`TerminalSession` and friends).
public enum TerminalWorkspaceError: PKError, Sendable, Equatable {
    /// The underlying PTY/shell process could not be spawned.
    case sessionSpawnFailed
    /// The shell process exited while a command was outstanding (or before any command ran).
    case shellExited
    /// `run` was called while a previous command is still pending completion.
    case commandAlreadyRunning
    /// An operation that requires an in-flight command was called with none pending.
    case notRunning
    /// The requested command id's full output has been evicted from the capped store.
    case commandOutputExpired
    /// The command id does not exist in the output store.
    case unknownCommandOutput

    public var errorDomain: String {
        PKErrorDomain.workspace
    }

    public var errorCode: Int {
        switch self {
        case .sessionSpawnFailed: return 1001
        case .shellExited: return 1002
        case .commandAlreadyRunning: return 1003
        case .notRunning: return 1004
        case .commandOutputExpired: return 1005
        case .unknownCommandOutput: return 1006
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .sessionSpawnFailed:
            return "The terminal session could not be started."
        case .shellExited:
            return "The terminal's shell process has exited."
        case .commandAlreadyRunning:
            return "A command is already running in this terminal session."
        case .notRunning:
            return "No command is currently running in this terminal session."
        case .commandOutputExpired:
            return "The terminal command's output has expired and is no longer available."
        case .unknownCommandOutput:
            return "The specified command output was not found."
        }
    }
}
