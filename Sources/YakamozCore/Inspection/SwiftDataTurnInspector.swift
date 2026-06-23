import Foundation
import PositronicKit
import SwiftData

public extension TurnInspectionModel {
    /// Decodes the persisted rendered-section projections.
    func decodedSections(decoder: JSONDecoder = JSONDecoder()) throws -> [InspectionSectionDTO] {
        try decoder.decode([InspectionSectionDTO].self, from: sectionsData)
    }

    /// Decodes the persisted sent-message projections.
    func decodedSentMessages(decoder: JSONDecoder = JSONDecoder()) throws -> [InspectionMessageDTO] {
        try decoder.decode([InspectionMessageDTO].self, from: sentMessagesData)
    }

    /// Decodes the persisted journal projection.
    func decodedJournal(decoder: JSONDecoder = JSONDecoder()) throws -> JournalDTO {
        try decoder.decode(JournalDTO.self, from: journalData)
    }

    /// Decodes the persisted response projection, when captured.
    func decodedResponse(decoder: JSONDecoder = JSONDecoder()) throws -> ResponseDTO? {
        guard let responseData else { return nil }
        return try decoder.decode(ResponseDTO.self, from: responseData)
    }
}

/// `TurnInspecting` adapter that confines a SwiftData `ModelContext` to persist
/// each `TurnInspection` as a `TurnInspectionModel`.
///
/// `ModelContext` is not `Sendable`; `@ModelActor` confines it to this actor so the
/// adapter can safely implement the `Sendable` `async` `TurnInspecting` protocol.
@ModelActor
public actor SwiftDataTurnInspector: TurnInspecting {
    public func didComposeTurn(_ inspection: TurnInspection) async {
        do {
            let projection = try InspectionProjection(inspection)
            modelContext.insert(projection.model)
            try modelContext.save()
        } catch {
            assertionFailure("Failed to persist turn inspection: \(error)")
        }
    }

    /// Fetches the persisted projection for a given conversation/turn pair, if any.
    ///
    /// Returns a `Sendable` value (not the `@Model`) so nothing crosses the actor
    /// boundary; the stored DTO `Data` is decoded here inside the actor.
    public func inspection(conversationId: UUID, turnIndex: Int) throws -> PersistedTurnInspection? {
        let key = "\(conversationId.uuidString):\(turnIndex)"
        var descriptor = FetchDescriptor<TurnInspectionModel>(predicate: #Predicate { $0.id == key })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        return try PersistedTurnInspection(model: model)
    }

    /// Enriches an already-persisted `TurnInspectionModel` with response metadata
    /// captured after the turn completes (reconstructed text/thinking, model,
    /// finish reason, token usage).
    ///
    /// `didComposeTurn` runs at prompt-assembly time, before the LLM has produced any
    /// output, so `responseData` starts `nil`; this is the seam that fills it in once
    /// `ChatViewModel.consume` observes `.streamCompleted` for the turn. JSON
    /// encode/decode happens inside the actor — the `@Model` itself never crosses the
    /// boundary.
    public func updateResponse(conversationId: UUID, turnIndex: Int, response: ResponseDTO) throws {
        let key = "\(conversationId.uuidString):\(turnIndex)"
        var descriptor = FetchDescriptor<TurnInspectionModel>(predicate: #Predicate { $0.id == key })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.responseData = try JSONEncoder().encode(response)
        try modelContext.save()
    }

    /// The highest persisted turn index for a conversation, or `nil` if none exist.
    ///
    /// A single `ChatViewModel` user send can drive several engine LLM round-trips (one
    /// per tool-resolution loop), each creating its own `didComposeTurn` inspection row.
    /// The final assistant text belongs to the *last* of those rows, so callers persisting
    /// response metadata target this index rather than the view model's own turn counter.
    public func latestTurnIndex(conversationId: UUID) throws -> Int? {
        var descriptor = FetchDescriptor<TurnInspectionModel>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.turnIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.turnIndex
    }

    /// Enriches the conversation's most recent inspection row with response metadata.
    ///
    /// Resolves the latest turn index (see `latestTurnIndex`) and delegates to
    /// `updateResponse`, so the final assistant response lands on the engine's last
    /// round-trip even when the view model only counts one logical turn. No-ops when the
    /// conversation has no inspection rows yet.
    public func updateLatestResponse(conversationId: UUID, response: ResponseDTO) throws {
        guard let turnIndex = try latestTurnIndex(conversationId: conversationId) else { return }
        try updateResponse(conversationId: conversationId, turnIndex: turnIndex, response: response)
    }
}
