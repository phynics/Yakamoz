import ErrorKit
import Foundation
import Logging
import PKShared

/// Convenience namespace providing labeled loggers for Yakamoz subsystems.
///
/// Each property returns a `Logger` with a stable label under `me.atkn.Yakamoz.*`,
/// automatically split by `YakamozLogHandler` into subsystem + category for Console.app filtering.
public enum Log {
    /// Optional test seam: when set, every `Log.*` logger is built with this handler factory
    /// instead of the global swift-log backend, so a test can capture emitted records (level +
    /// metadata) without re-bootstrapping the process-global `LoggingSystem`. `nil` in production,
    /// where loggers use whatever `YakamozLogging.bootstrap()` installed. See `Logging`'s own
    /// docs: `LoggingSystem.bootstrap` is one-shot per process, so a swappable factory is the
    /// supported way to record under test.
    nonisolated(unsafe) static var testHandlerFactory: (@Sendable (String) -> any LogHandler)?

    private static func makeLogger(label: String) -> Logger {
        if let factory = testHandlerFactory {
            return Logger(label: label, factory: factory)
        }
        return Logger(label: label)
    }

    /// Logger for app-level concerns (startup, shutdown, initialization).
    public static var app: Logger {
        makeLogger(label: "me.atkn.Yakamoz.app")
    }

    /// Logger for runtime composition and lifecycle.
    public static var runtime: Logger {
        makeLogger(label: "me.atkn.Yakamoz.runtime")
    }

    /// Logger for chat conversation and turn execution.
    public static var chat: Logger {
        makeLogger(label: "me.atkn.Yakamoz.chat")
    }

    /// Logger for workspace attachment and management.
    public static var workspace: Logger {
        makeLogger(label: "me.atkn.Yakamoz.workspace")
    }

    /// Logger for terminal shell sessions and command execution.
    public static var terminal: Logger {
        makeLogger(label: "me.atkn.Yakamoz.terminal")
    }

    /// Helper to get a user-friendly error message. Used by app startup to surface
    /// initialization errors in both logs and the UI.
    public static func userFriendlyErrorMessage(for error: Error) -> String {
        ErrorKit.userFriendlyMessage(for: error)
    }

    /// Logs an app-level error with optional structured metadata, accepting plain
    /// `[String: String]` so callers in the app target (which links only `YakamozCore`,
    /// not `Logging`) can emit filterable metadata without naming a `Logging.Logger.Metadata`
    /// type directly — keeping the app/`YakamozCore` boundary clean.
    public static func appError(_ message: String, metadata: [String: String] = [:]) {
        let loggerMetadata = Logger.Metadata(
            uniqueKeysWithValues: metadata.map { ($0.key, .string($0.value)) }
        )
        app.error("\(message)", metadata: loggerMetadata)
    }
}
