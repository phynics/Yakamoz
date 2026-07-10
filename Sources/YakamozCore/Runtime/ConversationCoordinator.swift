import Foundation
import PKShared
import PositronicKit
import SwiftData

/// Creates a new conversation, pairing one `ConversationModel` row (Yakamoz's UI shell)
/// with a `PositronicKit.Timeline` that shares the same `id` (see `YakamozRuntime` /
/// Task 7 integration notes: one `UUID` is used as both `ConversationModel.id` and the
/// PositronicKit `timelineId` so `ChatViewModel`/`ChatEngine.run(timelineId:)` can hydrate
/// the same conversation `ConversationListView` displays).
///
/// `ChatEngine.prepareSession` reads `TimelineManager.getTimeline(id:)`, which only
/// consults its in-memory cache and tolerates a `nil` result (the rendered prompt simply
/// omits timeline-specific context) — so a pre-existing `Timeline` is not strictly
/// required for `run` to succeed. We still persist one eagerly here because
/// `TimelinePersistenceProtocol` (and any future feature that lists/archives timelines,
/// e.g. `fetchAllTimelines`) expects every conversation to have a corresponding row.
@MainActor
public struct ConversationCoordinator {
    private let modelContext: ModelContext
    private let timelineStore: any TimelinePersistenceProtocol

    public init(modelContext: ModelContext, timelineStore: any TimelinePersistenceProtocol) {
        self.modelContext = modelContext
        self.timelineStore = timelineStore
    }

    /// Inserts a new `ConversationModel` and a paired `Timeline` sharing the same id,
    /// persists both, and returns the conversation.
    @discardableResult
    public func createConversation(
        title: String = "New Chat",
        personaId: UUID? = nil,
        workspaceId: UUID? = nil
    ) async throws -> ConversationModel {
        let id = UUID()
        let now = Date()

        let conversation = ConversationModel(
            id: id,
            title: title,
            createdAt: now,
            personaId: personaId,
            workspaceId: workspaceId
        )
        modelContext.insert(conversation)
        try modelContext.save()

        let timeline = Timeline(id: id, title: title, createdAt: now, updatedAt: now)
        try await timelineStore.saveTimeline(timeline)

        return conversation
    }

    /// Applies a `title` sidecar directive's outcome (SID-1): a non-null value replaces
    /// the conversation's title and resets the cadence counter; a decline, failure, or an
    /// unextractable payload leaves the title untouched but still advances the counter
    /// (the turn happened, whether or not the model produced a better title). No-ops
    /// silently if `result.name` is not `"title"` or the conversation cannot be found (a
    /// stale/cancelled turn racing conversation deletion — not an error worth surfacing).
    ///
    /// SID-3: the `.value` payload is the per-directive sub-object
    /// `TitleDirectivePayload`'s encoded form (`{"title": "..."}`, an `AnyCodable.dictionary`),
    /// not a bare string — so it is decoded via `sidecarPayloadString(forKey:)` with a
    /// single-string fallback for off-schema provider responses (e.g. `{"text": "..."}`).
    public func applyTitleDirective(conversationId: UUID, result: SidecarResult) async throws {
        guard result.name == TitleDirective.name else { return }
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == conversationId }
        )
        guard let conversation = try modelContext.fetch(descriptor).first else { return }

        switch result.outcome {
        case let .value(anyCodable):
            if let title = anyCodable.sidecarPayloadString(forKey: TitleDirective.payloadKey),
               !title.isEmpty
            {
                conversation.title = title
                conversation.hasReceivedTitleDirective = true
                conversation.turnsSinceLastTitleDirective = 0
            } else {
                conversation.turnsSinceLastTitleDirective += 1
            }
        case .declined, .failed:
            conversation.turnsSinceLastTitleDirective += 1
        }
        try modelContext.save()
    }

    /// Records a new navigation annotation for an accepted (non-null) section-title
    /// result (SID-2). No-ops on decline/failure — most turns are expected to decline,
    /// and that must not create noise in the navigation list. Also no-ops silently when
    /// `result.name` is not `"section_title"` or the payload cannot be decoded to a
    /// non-empty string. `turnIndex` anchors the annotation to the transcript turn it
    /// occurred on, so the navigation bar can map a chip tap back to a transcript turn.
    ///
    /// SID-3: the `.value` payload is the per-directive sub-object
    /// `SectionTitleDirectivePayload`'s encoded form
    /// (`{"sectionTitle": "..."}`, an `AnyCodable.dictionary`), not a bare string — so
    /// it is decoded via `sidecarPayloadString(forKey:)` with a single-string fallback for
    /// off-schema provider responses (e.g. `{"text": "..."}`).
    public func recordSectionTitleAnnotation(
        conversationId: UUID,
        turnIndex: Int,
        result: SidecarResult
    ) throws {
        guard result.name == SectionTitleDirective.name else { return }
        guard case let .value(anyCodable) = result.outcome,
              let text = anyCodable.sidecarPayloadString(forKey: SectionTitleDirective.payloadKey),
              !text.isEmpty else { return }
        let annotation = TimelineAnnotationModel(
            conversationId: conversationId,
            turnIndex: turnIndex,
            kind: .sectionTitle,
            text: text
        )
        modelContext.insert(annotation)
        try modelContext.save()
    }

    /// Returns the most recent section-title annotation's text for a conversation, or
    /// `nil` when none exists yet. Used by `YakamozRuntime.dueSidecarDirectives` to feed
    /// the `section_title` directive's "current section" context (mirroring SID-1's
    /// current-title feed). "Most recent" is the highest `turnIndex` (matches the
    /// conversation's reading order), with `createdAt` as a tiebreaker.
    public func fetchLatestSectionTitle(conversationId: UUID) throws -> String? {
        var descriptor = FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.turnIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let latest = try modelContext.fetch(descriptor).first else { return nil }
        return latest.text
    }

    /// Section-title annotations for a conversation's navigation bar (SID-2), sorted by
    /// the turn they anchor to — oldest first, matching timeline reading order. Empty
    /// when the conversation has produced no accepted section titles yet (the common
    /// case for short conversations that haven't shifted phases).
    public func fetchSectionAnnotations(conversationId: UUID) throws -> [TimelineAnnotationModel] {
        var descriptor = FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.turnIndex)]
        )
        // The navigation bar is the only consumer today; cap at a generous bound so a
        // runaway conversation with hundreds of phase shifts can't unbounded-grow the
        // chip list. The cadence model (one row per accepted directive, most turns
        // declining) makes this bound very unlikely to hit in practice.
        descriptor.fetchLimit = 200
        return try modelContext.fetch(descriptor)
    }
}
