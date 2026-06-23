import Foundation
import PKPrompt
import PKShared
import PositronicKit

/// Codable projection of a single `RenderedPrompt.Section`.
///
/// `RenderedPrompt.Section` is `Sendable` but not `Codable` (several of its traits
/// are enums from `PKPrompt` that intentionally don't conform to `Codable`). This
/// DTO captures every trait needed for the inspector UI using `String(describing:)`
/// for the enum-like fields that aren't `Codable`.
public struct InspectionSectionDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let parentID: String?
    public let path: [String]
    public let role: String
    public let priority: Int
    public let compression: String
    public let cachePolicy: String
    public let estimatedTokens: Int
    public let compressionOutcome: String?
    public let content: String

    public init(
        id: String,
        parentID: String?,
        path: [String],
        role: String,
        priority: Int,
        compression: String,
        cachePolicy: String,
        estimatedTokens: Int,
        compressionOutcome: String?,
        content: String
    ) {
        self.id = id
        self.parentID = parentID
        self.path = path
        self.role = role
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.estimatedTokens = estimatedTokens
        self.compressionOutcome = compressionOutcome
        self.content = content
    }

    init(section: RenderedPrompt.Section, rendered: RenderedPrompt) {
        id = section.id
        parentID = section.parentID
        path = section.path
        role = String(describing: section.role)
        priority = section.priority
        compression = String(describing: section.compression)
        cachePolicy = String(describing: section.cachePolicy)
        estimatedTokens = section.estimatedTokens
        compressionOutcome = section.compressionOutcome.map(String.init(describing:))
        content = rendered.sectionsByID[section.id] ?? section.content.text ?? ""
    }
}

/// Codable projection of a single `LLMMessage` sent to the provider.
public struct InspectionMessageDTO: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let toolCallID: String?

    public init(role: String, content: String, toolCallID: String?) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }

    init(message: LLMMessage) {
        role = message.role.rawValue
        content = message.content
        toolCallID = message.toolCallID
    }
}

/// Codable projection of a `TurnJournalSnapshot`.
public struct JournalDTO: Codable, Sendable, Equatable {
    public let changedSemiStableIDs: [String]
    public let addedSemiStableIDs: [String]
    public let removedSemiStableIDs: [String]
    public let stablePrefixCount: Int
    public let didCompact: Bool

    public init(
        changedSemiStableIDs: [String],
        addedSemiStableIDs: [String],
        removedSemiStableIDs: [String],
        stablePrefixCount: Int,
        didCompact: Bool
    ) {
        self.changedSemiStableIDs = changedSemiStableIDs
        self.addedSemiStableIDs = addedSemiStableIDs
        self.removedSemiStableIDs = removedSemiStableIDs
        self.stablePrefixCount = stablePrefixCount
        self.didCompact = didCompact
    }

    init(journal: TurnJournalSnapshot) {
        changedSemiStableIDs = journal.overlay.changedSemiStableIDs
        addedSemiStableIDs = journal.overlay.addedSemiStableIDs
        removedSemiStableIDs = journal.overlay.removedSemiStableIDs
        stablePrefixCount = journal.stablePrefixCount
        didCompact = journal.didCompact
    }
}

/// Codable projection of captured response metadata for a turn.
///
/// `TurnInspection` does not currently carry response metadata; this DTO exists so
/// `TurnInspectionModel.responseData` has a stable shape ready for a future turn
/// where response capture is wired up (see `responseData` usage in
/// `SwiftDataTurnInspector`).
public struct ResponseDTO: Codable, Sendable, Equatable {
    public var reconstructedText: String
    public var thinking: String
    public var model: String?
    public var finishReason: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(
        reconstructedText: String,
        thinking: String,
        model: String? = nil,
        finishReason: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.reconstructedText = reconstructedText
        self.thinking = thinking
        self.model = model
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Converts a `TurnInspection` into a persistable `TurnInspectionModel` plus the
/// decoded DTOs used to build it, encoding the Codable projections to `Data`.
public struct InspectionProjection {
    public let model: TurnInspectionModel
    public let sections: [InspectionSectionDTO]
    public let sentMessages: [InspectionMessageDTO]
    public let journal: JournalDTO

    public init(_ inspection: TurnInspection, encoder: JSONEncoder = JSONEncoder()) throws {
        let sections = inspection.rendered.sections.map {
            InspectionSectionDTO(section: $0, rendered: inspection.rendered)
        }
        let sentMessages = inspection.sentMessages.map(InspectionMessageDTO.init(message:))
        let journal = JournalDTO(journal: inspection.journal)

        self.sections = sections
        self.sentMessages = sentMessages
        self.journal = journal

        let sectionsData = try encoder.encode(sections)
        let sentMessagesData = try encoder.encode(sentMessages)
        let journalData = try encoder.encode(journal)

        model = TurnInspectionModel(
            conversationId: inspection.timelineId,
            turnIndex: inspection.turnIndex,
            model: inspection.model,
            sectionsData: sectionsData,
            sentMessagesData: sentMessagesData,
            journalData: journalData,
            estimatedTokens: inspection.estimatedTokens,
            responseData: nil
        )
    }
}

/// A `Sendable` value projection of a persisted `TurnInspectionModel`.
///
/// `TurnInspectionModel` is a SwiftData `@Model` (not `Sendable`), so it must not
/// cross the `SwiftDataTurnInspector` actor boundary. Reads decode the stored DTO
/// `Data` inside the actor and return this immutable value instead.
public struct PersistedTurnInspection: Sendable, Equatable {
    public let conversationId: UUID
    public let turnIndex: Int
    public let model: String
    public let createdAt: Date
    public let estimatedTokens: Int
    public let sections: [InspectionSectionDTO]
    public let sentMessages: [InspectionMessageDTO]
    public let journal: JournalDTO
    public let response: ResponseDTO?

    public init(
        conversationId: UUID,
        turnIndex: Int,
        model: String,
        createdAt: Date,
        estimatedTokens: Int,
        sections: [InspectionSectionDTO],
        sentMessages: [InspectionMessageDTO],
        journal: JournalDTO,
        response: ResponseDTO?
    ) {
        self.conversationId = conversationId
        self.turnIndex = turnIndex
        self.model = model
        self.createdAt = createdAt
        self.estimatedTokens = estimatedTokens
        self.sections = sections
        self.sentMessages = sentMessages
        self.journal = journal
        self.response = response
    }

    /// Decodes a persisted model into a Sendable value. Call inside the model actor.
    public init(model: TurnInspectionModel) throws {
        try self.init(
            conversationId: model.conversationId,
            turnIndex: model.turnIndex,
            model: model.model,
            createdAt: model.createdAt,
            estimatedTokens: model.estimatedTokens,
            sections: model.decodedSections(),
            sentMessages: model.decodedSentMessages(),
            journal: model.decodedJournal(),
            response: model.decodedResponse()
        )
    }
}
