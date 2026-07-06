import Foundation
import JSONSchemaBuilder
import PKShared

/// The payload shape for the `title` sidecar directive (SID-1): a single optional string.
/// `nil`/absent means "no meaningfully better title exists yet" — a valid, non-error
/// outcome, not a decline the model is being tricked into avoiding.
@Schemable
public struct TitleDirectivePayload: Codable, Sendable, Equatable {
    public let title: String?

    public init(title: String?) {
        self.title = title
    }
}

/// SID-1: the `title` sidecar directive — piggy-backed onto the turn's structured-output
/// payload, requesting a conversation title only when a meaningfully better one exists.
///
/// Cadence (which turns carry this directive at all) is decided by the caller
/// (`TitleSidecarSchedule`, Task 4) — this type only describes *what* to ask for once a
/// turn has been selected to carry it.
public enum TitleDirective {
    public static let name = "title"

    /// Builds the directive, embedding `currentTitle` so the model can judge "meaningfully
    /// better" against the conversation's existing title (or the absence of one).
    public static func make(currentTitle: String?) -> SidecarDirective {
        let context = currentTitle.map { "The conversation's current title is: \"\($0)\"." }
            ?? "The conversation does not have a title yet."
        return SidecarDirective(
            name: name,
            instruction: """
            \(context) Produce a short (3-8 word) title for this conversation only if a \
            meaningfully better title now exists than before (or none existed). Otherwise \
            return null. A null response is expected and correct most of the time — do not \
            invent a marginally different title just to have something to say.
            """,
            schema: TitleDirectivePayload.schema.definition(),
            streaming: .buffered,
            timing: .afterResponse
        )
    }
}
