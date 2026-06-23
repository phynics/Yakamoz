import Foundation
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
}
