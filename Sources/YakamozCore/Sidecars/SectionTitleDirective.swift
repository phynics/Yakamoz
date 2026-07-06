import Foundation
import JSONSchemaBuilder
import PKShared

/// The payload shape for the `section_title` sidecar directive (SID-2): a single
/// optional string, mirroring `TitleDirectivePayload`. `nil`/absent means "this turn
/// did not mark a genuinely new phase" — a valid, expected non-answer for the majority
/// of turns in a conversation that continues the current section.
@Schemable
public struct SectionTitleDirectivePayload: Codable, Sendable, Equatable {
    public let sectionTitle: String?

    public init(sectionTitle: String?) {
        self.sectionTitle = sectionTitle
    }
}

/// SID-2: the `section_title` sidecar directive. Rides every sidecar-enabled turn
/// (no schedule, unlike `TitleDirective`) — the optional-response contract keeps it
/// cheap: the instruction asks the model to return null unless the conversation has
/// shifted to a meaningfully new phase.
///
/// The "current section title" context (mirroring SID-1's current-title feed) is the
/// *last emitted* annotation's text, supplied by the caller (`YakamozRuntime`'s
/// `dueSidecarDirectives`); it is not a `ConversationModel` field because section
/// titles are turn-anchored navigation markers (`TimelineAnnotationModel`), not a
/// single mutable value.
public enum SectionTitleDirective {
    public static let name = "section_title"

    public static func make(currentSectionTitle: String?) -> SidecarDirective {
        let context = currentSectionTitle.map { "The current section is: \"\($0)\"." }
            ?? "No section has been marked yet."
        return SidecarDirective(
            name: name,
            instruction: """
            \(context) Return a short (2-6 word) section title only if this turn marks a \
            genuinely new phase of the conversation (e.g. moving from diagnosis to \
            implementation). Otherwise return null — most turns continue the current \
            section and should return null.
            """,
            schema: SectionTitleDirectivePayload.schema.definition(),
            streaming: .buffered,
            timing: .afterResponse
        )
    }
}
