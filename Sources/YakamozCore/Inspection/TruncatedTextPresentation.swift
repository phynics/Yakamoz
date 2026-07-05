import Foundation

/// Presentation-level projection that caps how much of a potentially huge string
/// (e.g. a sent message's `content`, which may include a tens-of-thousands-of-characters
/// system prompt) is initially rendered, with an explicit expansion affordance.
///
/// macOS `.textSelection(.enabled)` forces an AppKit text-layout pass over the full
/// string; laying out huge strings inside a `LazyVStack` as rows materialize during
/// scroll stalls the main thread. Capping the initially-rendered length keeps layout
/// cheap while keeping full content reachable via expansion (and always copyable via
/// the un-truncated `fullText`).
public struct TruncatedTextPresentation: Equatable, Sendable {
    /// Default cap on initially-rendered characters per message (UIX-6).
    public static let defaultThreshold = 2000

    public let fullText: String
    public let threshold: Int

    public init(fullText: String, threshold: Int = TruncatedTextPresentation.defaultThreshold) {
        self.fullText = fullText
        self.threshold = threshold
    }

    /// Whether `fullText` exceeds `threshold` and thus needs truncation/expansion.
    public var isTruncatable: Bool {
        fullText.count > threshold
    }

    /// The full character count of `fullText`.
    public var characterCount: Int {
        fullText.count
    }

    /// The text to render when collapsed: the full text if it's short enough to not
    /// need truncation, otherwise the first `threshold` characters.
    public var collapsedText: String {
        guard isTruncatable else { return fullText }
        return String(fullText.prefix(threshold))
    }

    /// Text to render given the current expansion state: `fullText` when expanded (or
    /// when not truncatable), `collapsedText` otherwise.
    public func displayedText(isExpanded: Bool) -> String {
        if !isTruncatable || isExpanded {
            return fullText
        }
        return collapsedText
    }

    /// Label for the expander affordance, e.g. "Show all 12,345 characters".
    public var expanderLabel: String {
        "Show all \(Self.groupedDecimalString(characterCount)) characters"
    }

    /// Formats a non-negative integer with comma thousands separators, independent of
    /// the current locale (this is developer-facing diagnostic UI, not localized copy).
    private static func groupedDecimalString(_ value: Int) -> String {
        let digits = Array(String(value))
        var result = ""
        for (index, digit) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 {
                result.append(",")
            }
            result.append(digit)
        }
        return String(result.reversed())
    }
}
