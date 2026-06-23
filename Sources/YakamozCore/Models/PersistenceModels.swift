import Foundation
import SwiftData

/// A persisted conversation (timeline) shell.
@Model
public final class ConversationModel {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var personaId: UUID?
    public var enabledToolIds: [String]
    public var workspaceId: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        personaId: UUID? = nil,
        enabledToolIds: [String] = [],
        workspaceId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.personaId = personaId
        self.enabledToolIds = enabledToolIds
        self.workspaceId = workspaceId
    }
}

/// A persisted chat message belonging to a conversation.
@Model
public final class MessageModel {
    @Attribute(.unique) public var id: UUID
    public var conversationId: UUID
    public var role: String
    public var content: String
    public var toolCallsData: Data?
    public var createdAt: Date
    public var remoteDepth: Int

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: String,
        content: String,
        toolCallsData: Data? = nil,
        createdAt: Date = .now,
        remoteDepth: Int = 0
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolCallsData = toolCallsData
        self.createdAt = createdAt
        self.remoteDepth = remoteDepth
    }
}

/// A persisted projection of a single `TurnInspection`, keyed by
/// `(conversationId, turnIndex)`. The Codable projections (`sections`,
/// `sentMessages`, `journal`, `response`) are stored as encoded `Data` so schema
/// evolution of the underlying DTOs is explicit rather than implicit in the
/// `@Model` storage format.
@Model
public final class TurnInspectionModel {
    @Attribute(.unique) public var id: String
    public var conversationId: UUID
    public var turnIndex: Int
    public var model: String
    public var createdAt: Date
    public var sectionsData: Data
    public var sentMessagesData: Data
    public var journalData: Data
    public var estimatedTokens: Int
    public var responseData: Data?

    public init(
        conversationId: UUID,
        turnIndex: Int,
        model: String,
        createdAt: Date = .now,
        sectionsData: Data,
        sentMessagesData: Data,
        journalData: Data,
        estimatedTokens: Int,
        responseData: Data? = nil
    ) {
        id = "\(conversationId.uuidString):\(turnIndex)"
        self.conversationId = conversationId
        self.turnIndex = turnIndex
        self.model = model
        self.createdAt = createdAt
        self.sectionsData = sectionsData
        self.sentMessagesData = sentMessagesData
        self.journalData = journalData
        self.estimatedTokens = estimatedTokens
        self.responseData = responseData
    }
}

/// A persisted persona (system-instruction preset).
@Model
public final class PersonaModel {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var systemInstructions: String
    public var builtIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        systemInstructions: String,
        builtIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemInstructions = systemInstructions
        self.builtIn = builtIn
    }
}

/// A persisted folder-backed workspace reference.
@Model
public final class WorkspaceModel {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var folderPath: String
    public var bookmarkData: Data?

    public init(
        id: UUID = UUID(),
        displayName: String,
        folderPath: String,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.folderPath = folderPath
        self.bookmarkData = bookmarkData
    }
}
