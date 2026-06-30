import Foundation
import Logging

/// Bootstraps `swift-log` to route all logging output to Apple's unified logging system.
///
/// Call this once at app startup (e.g., as the first line of `YakamozApp.init()`) to wire
/// both Yakamoz and PositronicKit logging through a single `os.Logger` backend. The call is
/// idempotent and safe to invoke multiple times (e.g., during runtime construction in tests).
public enum YakamozLogging {
    private nonisolated(unsafe) static var isBootstrapped = false
    private static let bootstrapLock = NSLock()

    /// Bootstraps swift-log to route all output to os.Logger, if not already bootstrapped.
    /// Safe to call multiple times; subsequent calls are no-ops.
    public static func bootstrap() {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        guard !isBootstrapped else { return }

        LoggingSystem.bootstrap { label in
            YakamozLogHandler(label: label)
        }

        isBootstrapped = true
    }

    /// Resets the bootstrap state for testing. Allows tests to verify bootstrap idempotency.
    /// **Not for production use.**
    static func resetForTesting() {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        isBootstrapped = false
        YakamozLogHandler.resetCacheForTesting()
    }
}
