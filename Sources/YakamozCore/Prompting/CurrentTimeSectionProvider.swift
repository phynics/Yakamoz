import Foundation
import PositronicKit

/// Contributes the current wall-clock time through PositronicKit v4's bounded Turn context seam.
/// The clock is injected so tests can assert deterministic content.
public struct CurrentTimeContextSource: TurnContextSource {

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

    public func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        [try TurnContextContribution(
            namespace: "yakamoz",
            key: "current-time",
            text: Self.content(for: now())
        )]
    }
}
