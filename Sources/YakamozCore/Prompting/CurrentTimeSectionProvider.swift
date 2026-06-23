import Foundation
import PKPrompt
import PositronicKit

/// Injects the current wall-clock time as a low-priority, volatile prompt section into
/// every chat turn for its timeline.
///
/// Registered with the runtime via `PositronicKit.init(sectionProviders:)` /
/// `RuntimeConfiguration.sectionProviders`, which forwards to
/// `TimelineManager.init(sectionProviders:)`. The facade then calls
/// `TimelineManager.gatherExtensionSections(...)` during prompt assembly, so the section
/// participates in priority sorting and token-budget decisions automatically.
///
/// The clock is injected so tests can assert deterministic ISO-8601 content against a fixed
/// instant; production uses `Date.init` (the live clock).
public struct CurrentTimeSectionProvider: PromptSectionProviding {
    /// Stable section id so the inspector and journal can track it across turns.
    public static let sectionID = "yakamoz.current-time"

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The ISO-8601 rendering of `date` used as the section's content. Exposed for tests
    /// so they can assert the exact string without constructing a prompt.
    public static func content(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return "Current time (UTC): \(formatter.string(from: date))"
    }

    public func sections(for _: PromptBuildContext) async -> [any Prompt] {
        let text = Self.content(for: now())
        return [
            TextPrompt(
                text,
                id: Self.sectionID,
                priority: PromptPriority.low.rawValue,
                compression: .keep,
                cachePolicy: .volatile
            ),
        ]
    }
}
