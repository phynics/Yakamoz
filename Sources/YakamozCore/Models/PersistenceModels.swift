import Foundation
import SwiftData

/// Single source of truth for the full SwiftData schema: every `@Model` type that must
/// be registered with the production `ModelContainer`. Use `Schema(YakamozSchema.models)`
/// when building the app's container so persistence never silently drops a model type.
public enum YakamozSchema {
    public static let models: [any PersistentModel.Type] = [
        ConversationModel.self,
        MessageModel.self,
        TurnInspectionModel.self,
        PersonaModel.self,
        WorkspaceModel.self,
        TimelineModel.self,
        WorkspaceReferenceModel.self,
        ToolReferenceModel.self,
        AgentInstanceModel.self,
        AgentTemplateModel.self,
        RequestOriginModel.self,
    ]
}

/// Sidebar-facing conversation activity state (YAK-29).
///
/// Stored on `ConversationModel` rather than `TimelineModel` so the SwiftUI list can query and
/// render it directly without introducing a separate projection layer for every row.
public enum ConversationTimelineState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case tooling
    case completed
    case blocked
    case failed
    case cancelled

    /// Lower numbers sort earlier in the sidebar when conversations are prioritized.
    public var sortPriority: Int {
        switch self {
        case .tooling: 0
        case .running: 1
        case .blocked: 2
        case .failed: 3
        case .cancelled: 4
        case .completed: 5
        case .idle: 6
        }
    }
}

/// A persisted conversation (timeline) shell.
///
/// **Ownership boundary (YAK-6).** Yakamoz keeps two distinct model families that a
/// conversation pairs on one shared `UUID` (see `ConversationCoordinator`):
/// - `ConversationModel` (this type) is the **UI shell** and is the source of truth
///   for the user-facing conversation surface the app drives directly: `title`,
///   `createdAt`, persona/tool selection (`personaId`, `personaSlug`, `enabledToolIds`),
///   attached `workspaceId`, and the typed-reply / autonomous-follow-up toggles.
/// - `TimelineModel` is the **PositronicKit-protocol surface** (`TimelinePersistenceProtocol`)
///   and owns the runtime timeline lifecycle: `isArchived`, `workingDirectory`,
///   attached workspace/agent ids, `isPrivate`, and `updatedAt`.
///
/// Fields that overlap by name (`title`, `createdAt`) are duplicated by design: the
/// UI shell writes its own copy and does not currently derive from the timeline. The
/// two id spaces share a value but are separate columns; if they ever disagree,
/// `ConversationModel` wins for anything the UI renders and `TimelineModel` wins for
/// anything the runtime/protocol consumes (archival, working directory). Reconciling
/// the duplication into a derived/synced relationship is deferred (YAK-6 part 2).
@Model
public final class ConversationModel {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var personaId: UUID?
    public var enabledToolIds: [String]
    public var workspaceId: UUID?
    /// Stable persona slug ("helpful"/"reviewer"/...) for built-in personas, or the
    /// `UUID` string of a custom `PersonaModel`. Distinct from `personaId` (the
    /// agent-instance linkage); this drives the toolbar persona picker selection.
    public var personaSlug: String?
    /// When `true`, the conversation requests typed (structured) replies and the Response
    /// inspector tab shows the schema + parsed/validated JSON (Task 10).
    public var typedReplyEnabled: Bool
    /// When `true`, an `AutonomousFollowUpPlugin` injects one bounded follow-up per send.
    public var autonomousFollowUpEnabled: Bool
    /// Multi-attach workspace ids (YAK-T1). `workspaceId` is the deprecated single-attach
    /// predecessor, retained only so existing stores migrate without a versioned schema.
    public var attachedWorkspaceIds: [UUID] = []
    /// Persisted list-facing state (YAK-29). Stored as a raw string for lightweight migration.
    public var timelineStateRaw: String = ConversationTimelineState.idle.rawValue
    /// Timestamp of the last state transition used for sidebar prioritization among peers.
    public var timelineStateUpdatedAt: Date = Date()

    /// Legacy single id folded with the new array; the rest of the app reads this.
    public var allAttachedWorkspaceIds: [UUID] {
        var ids = attachedWorkspaceIds
        if let legacy = workspaceId, !ids.contains(legacy) { ids.insert(legacy, at: 0) }
        return ids
    }

    public var timelineState: ConversationTimelineState {
        get { ConversationTimelineState(rawValue: timelineStateRaw) ?? .idle }
        set { timelineStateRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        personaId: UUID? = nil,
        enabledToolIds: [String] = [],
        workspaceId: UUID? = nil,
        attachedWorkspaceIds: [UUID] = [],
        personaSlug: String? = nil,
        typedReplyEnabled: Bool = false,
        autonomousFollowUpEnabled: Bool = false,
        timelineState: ConversationTimelineState = .idle,
        timelineStateUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.personaId = personaId
        self.enabledToolIds = enabledToolIds
        self.workspaceId = workspaceId
        self.attachedWorkspaceIds = attachedWorkspaceIds
        self.personaSlug = personaSlug
        self.typedReplyEnabled = typedReplyEnabled
        self.autonomousFollowUpEnabled = autonomousFollowUpEnabled
        timelineStateRaw = timelineState.rawValue
        self.timelineStateUpdatedAt = timelineStateUpdatedAt
    }
}

/// A persisted chat message belonging to a conversation.
@Model
public final class MessageModel {
    @Attribute(.unique) public var id: UUID
    public var conversationId: UUID
    public var role: String
    public var content: String
    /// JSON-encoded `ConversationMessage` envelope carrying every non-scalar field
    /// (recalledMemories, parentId, think, toolCalls, toolCallId, agentInstanceId,
    /// snapshotData, …). The scalar columns above are the authoritative queryable
    /// copy; this blob carries the rest. (Renamed from the historical `toolCallsData`,
    /// which only described one of the fields it actually stores — YAK-6.)
    public var messageEnvelopeData: Data?
    public var createdAt: Date
    public var remoteDepth: Int

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: String,
        content: String,
        messageEnvelopeData: Data? = nil,
        createdAt: Date = .now,
        remoteDepth: Int = 0
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.messageEnvelopeData = messageEnvelopeData
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
/// Discriminates a `WorkspaceModel` between a plain folder workspace and a terminal
/// (PTY shell) workspace. Stored as a raw `String` so the additive `kind` field decodes
/// to `.folder` for existing rows under SwiftData's automatic lightweight migration.
public enum WorkspaceKind: String, Codable, Sendable {
    case folder
    case terminal
}

@Model
public final class WorkspaceModel {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var folderPath: String
    public var bookmarkData: Data?
    /// Workspace kind (YAK-T4). Defaults to `.folder` so existing rows decode unchanged
    /// under automatic lightweight migration. A terminal workspace stores its originating
    /// folder path in `folderPath` (used as the shell's initial working directory).
    public var kind: WorkspaceKind = WorkspaceKind.folder

    public init(
        id: UUID = UUID(),
        displayName: String,
        folderPath: String,
        bookmarkData: Data? = nil,
        kind: WorkspaceKind = .folder
    ) {
        self.id = id
        self.displayName = displayName
        self.folderPath = folderPath
        self.bookmarkData = bookmarkData
        self.kind = kind
    }
}

/// A persisted `PositronicKit.Timeline` (chat timeline lifecycle/metadata).
///
/// Distinct from `ConversationModel` (Yakamoz's own UI conversation shell, Task 3):
/// this entity exists to satisfy `TimelinePersistenceProtocol`'s richer surface
/// (archival, working directory, attached workspace/agent ids, privacy).
@Model
public final class TimelineModel {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var workingDirectory: String?
    /// JSON-encoded `[UUID]` of attached workspace ids.
    public var attachedWorkspaceIdsData: Data
    public var attachedAgentInstanceId: UUID?
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false,
        workingDirectory: String? = nil,
        attachedWorkspaceIdsData: Data = Data("[]".utf8),
        attachedAgentInstanceId: UUID? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.workingDirectory = workingDirectory
        self.attachedWorkspaceIdsData = attachedWorkspaceIdsData
        self.attachedAgentInstanceId = attachedAgentInstanceId
        self.isPrivate = isPrivate
    }
}

/// A persisted `PositronicKit.WorkspaceReference` (runtime/virtual document workspace).
///
/// Distinct from `WorkspaceModel` (Yakamoz's folder-backed workspace, Task 3): this
/// entity stores the full `WorkspaceReference` surface (URI, trust level, metadata,
/// origin attribution) needed by `WorkspacePersistenceProtocol`. Nested `tools` are
/// stored separately as `ToolReferenceModel` rows keyed by `workspaceId`.
@Model
public final class WorkspaceReferenceModel {
    @Attribute(.unique) public var id: UUID
    public var uriHost: String
    public var uriPath: String
    public var locationRaw: String
    public var originId: UUID?
    public var rootPath: String?
    public var trustLevelRaw: String
    public var lastModifiedBy: UUID?
    public var statusRaw: String
    /// JSON-encoded `[String: AnyCodable]`.
    public var metadataData: Data
    public var contextInjection: String?
    public var createdAt: Date

    public init(
        id: UUID,
        uriHost: String,
        uriPath: String,
        locationRaw: String,
        originId: UUID? = nil,
        rootPath: String? = nil,
        trustLevelRaw: String,
        lastModifiedBy: UUID? = nil,
        statusRaw: String,
        metadataData: Data = Data("{}".utf8),
        contextInjection: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.uriHost = uriHost
        self.uriPath = uriPath
        self.locationRaw = locationRaw
        self.originId = originId
        self.rootPath = rootPath
        self.trustLevelRaw = trustLevelRaw
        self.lastModifiedBy = lastModifiedBy
        self.statusRaw = statusRaw
        self.metadataData = metadataData
        self.contextInjection = contextInjection
        self.createdAt = createdAt
    }
}

/// A persisted `PositronicKit.ToolReference`, scoped to a workspace.
///
/// Encodes the full `ToolReference` enum (known-by-id or custom-definition) as
/// `Data` so the `.custom` case's nested `WorkspaceToolDefinition` round-trips
/// without a second `@Model` type.
@Model
public final class ToolReferenceModel {
    @Attribute(.unique) public var id: String
    public var workspaceId: UUID
    public var toolId: String
    /// JSON-encoded `ToolReference`.
    public var referenceData: Data

    public init(
        workspaceId: UUID,
        toolId: String,
        referenceData: Data
    ) {
        id = "\(workspaceId.uuidString):\(toolId)"
        self.workspaceId = workspaceId
        self.toolId = toolId
        self.referenceData = referenceData
    }
}

/// A persisted `PositronicKit.AgentInstance`.
@Model
public final class AgentInstanceModel {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Named `instanceDescription`, not `description` — SwiftData's `@Model` macro
    /// rejects a stored property literally named `description` (collides with
    /// `CustomStringConvertible`).
    public var instanceDescription: String
    public var primaryWorkspaceId: UUID?
    public var privateTimelineId: UUID
    public var lastActiveAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    /// JSON-encoded `[String: AnyCodable]`.
    public var metadataData: Data

    public init(
        id: UUID,
        name: String,
        instanceDescription: String,
        primaryWorkspaceId: UUID? = nil,
        privateTimelineId: UUID,
        lastActiveAt: Date = .now,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        metadataData: Data = Data("{}".utf8)
    ) {
        self.id = id
        self.name = name
        self.instanceDescription = instanceDescription
        self.primaryWorkspaceId = primaryWorkspaceId
        self.privateTimelineId = privateTimelineId
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataData = metadataData
    }
}

/// A persisted `PositronicKit.AgentTemplate`.
@Model
public final class AgentTemplateModel {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Named `templateDescription`, not `description` — see `AgentInstanceModel.instanceDescription`.
    public var templateDescription: String
    public var systemPrompt: String
    public var personaPrompt: String?
    public var guardrailsPrompt: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// JSON-encoded `[String: String]?`.
    public var workspaceFilesSeedData: Data?

    public init(
        id: UUID,
        name: String,
        templateDescription: String,
        systemPrompt: String,
        personaPrompt: String? = nil,
        guardrailsPrompt: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        workspaceFilesSeedData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.templateDescription = templateDescription
        self.systemPrompt = systemPrompt
        self.personaPrompt = personaPrompt
        self.guardrailsPrompt = guardrailsPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspaceFilesSeedData = workspaceFilesSeedData
    }
}

/// A persisted `PositronicKit.RequestOriginIdentity`.
@Model
public final class RequestOriginModel {
    @Attribute(.unique) public var id: UUID
    public var hostname: String
    public var displayName: String
    public var platform: String
    public var registeredAt: Date
    public var lastSeenAt: Date?

    public init(
        id: UUID = UUID(),
        hostname: String,
        displayName: String,
        platform: String,
        registeredAt: Date = .now,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.displayName = displayName
        self.platform = platform
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
    }
}
