import Foundation
import Logging
import os

/// A `LogHandler` that bridges `swift-log` records to Apple's unified logging (`os.Logger`).
///
/// This handler:
/// - Caches one `os.Logger(subsystem:category:)` per unique subsystem/category pair
/// - Splits dotted labels to derive subsystem and category:
///   - `com.positronickit.chat-engine` → subsystem: `com.positronickit`, category: `chat-engine`
///   - `me.atkn.Yakamoz.runtime` → subsystem: `me.atkn.Yakamoz`, category: `runtime`
/// - Maps `Logger.Level` to `OSLogType`:
///   - `.trace/.debug` → `.debug`
///   - `.info/.notice` → `.info`
///   - `.warning` → `.default`
///   - `.error` → `.error`
///   - `.critical` → `.fault`
/// - Merges swift-log metadata into the log message
struct YakamozLogHandler: LogHandler {
    private nonisolated(unsafe) static var loggers: [String: os.Logger] = [:]
    private static let lock = NSLock()

    let label: String

    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source _: String,
        file _: String,
        line _: UInt,
        function _: String
    ) {
        let mergedMetadata = self.metadata.merging(metadata ?? [:]) { _, new in new }

        // Format the message with metadata
        var formattedMessage = String(describing: message)
        if !mergedMetadata.isEmpty {
            let metadataString = mergedMetadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            formattedMessage = "\(formattedMessage) [\(metadataString)]"
        }

        // Get or create the os.Logger for this label's subsystem/category
        let osLogger = Self.cachedLogger(for: label)
        let osLogType = osLogType(for: level)

        osLogger.log(level: osLogType, "\(formattedMessage)")
    }

    subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    // MARK: - Internal Helpers

    func osLogType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug:
            return .debug
        case .info, .notice:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }

    func splitLabel(_ label: String) -> (subsystem: String, category: String) {
        let components = label.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        // Look for known subsystem prefixes
        if components.count >= 3, components[0] == "com", components[1] == "positronickit" {
            let subsystem = "com.positronickit"
            let category = components.dropFirst(2).joined(separator: ".")
            return (subsystem, category)
        }

        if components.count >= 4, components[0] == "me", components[1] == "atkn", components[2] == "Yakamoz" {
            let subsystem = "me.atkn.Yakamoz"
            let category = components.dropFirst(3).joined(separator: ".")
            return (subsystem, category)
        }

        // Fallback: use the last segment as category, everything else as subsystem
        if components.count > 1 {
            let subsystem = components.dropLast().joined(separator: ".")
            let category = components.last ?? ""
            return (subsystem, category)
        }

        // Single component: treat as subsystem with empty category
        return (label, "")
    }

    // MARK: - Logger Caching

    private static func cachedLogger(for label: String) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }

        let key = label
        if let cached = loggers[key] {
            return cached
        }

        let handler = YakamozLogHandler(label: label)
        let (subsystem, category) = handler.splitLabel(label)
        let logger = os.Logger(subsystem: subsystem, category: category)
        loggers[key] = logger
        return logger
    }

    // MARK: - Testing Support

    /// Clears the logger cache. Used by tests to reset state between runs.
    static func resetCacheForTesting() {
        lock.lock()
        defer { lock.unlock() }
        loggers.removeAll()
    }
}
