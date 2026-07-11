import Foundation
import SwiftData

public enum YakamozSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [ConversationModel.self, MessageModel.self, TurnInspectionModel.self, PersonaModel.self,
         AgentModel.self, WorkspaceModel.self, TimelineModel.self, WorkspaceReferenceModel.self,
         ToolReferenceModel.self, AgentInstanceModel.self, AgentTemplateModel.self,
         RequestOriginModel.self, TimelineAnnotationModel.self]
    }

    @Model public final class ConversationModel {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var createdAt: Date
        public var personaId: UUID?
        public var agentId: UUID?
        public var enabledToolIds: [String]
        public var workspaceId: UUID?
        public var personaSlug: String?
        public var sidecarDirectivesEnabled: Bool
        public var hasReceivedTitleDirective: Bool = false
        public var turnsSinceLastTitleDirective: Int = 0
        public var attachedWorkspaceIds: [UUID] = []
        public var timelineStateRaw: String = ConversationTimelineState.idle.rawValue
        public var timelineStateUpdatedAt: Date = Date()

        public init(id: UUID = UUID(), title: String, personaId: UUID? = nil,
                    workspaceId: UUID? = nil, attachedWorkspaceIds: [UUID] = [],
                    personaSlug: String? = nil) {
            self.id = id; self.title = title; createdAt = .now
            self.personaId = personaId; agentId = nil; enabledToolIds = []
            self.workspaceId = workspaceId; self.personaSlug = personaSlug
            sidecarDirectivesEnabled = false; self.attachedWorkspaceIds = attachedWorkspaceIds
        }
    }
}

public enum YakamozSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { YakamozSchema.models }
}

public enum YakamozSchemaV1_5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 5, 0)
    public static var models: [any PersistentModel.Type] {
        YakamozSchemaV1.models + [ConversationMigrationPayload.self]
    }
}

public enum YakamozMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [YakamozSchemaV1.self, YakamozSchemaV1_5.self, YakamozSchemaV2.self] }
    public static var stages: [MigrationStage] { [v1ToV1_5, v1_5ToV2] }
    private static let v1ToV1_5 = MigrationStage.lightweight(fromVersion: YakamozSchemaV1.self, toVersion: YakamozSchemaV1_5.self)
    private static let v1_5ToV2 = MigrationStage.custom(
        fromVersion: YakamozSchemaV1_5.self,
        toVersion: YakamozSchemaV2.self,
        willMigrate: { context in
            for conversation in try context.fetch(FetchDescriptor<YakamozSchemaV1.ConversationModel>()) {
                context.insert(ConversationMigrationPayload(
                    conversationId: conversation.id,
                    personaId: conversation.personaId,
                    workspaceId: conversation.workspaceId,
                    personaSlug: conversation.personaSlug
                ))
            }
            try context.save()
        },
        didMigrate: { context in
            var agentsBySlug = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AgentModel>()).compactMap { agent in agent.seedSlug.map { ($0, agent) } })
            let payloads = try context.fetch(FetchDescriptor<ConversationMigrationPayload>())
            let conversations = try context.fetch(FetchDescriptor<ConversationModel>())
            for conversation in conversations {
                guard let legacy = payloads.first(where: { $0.conversationId == conversation.id }) else { continue }
                if let workspaceId = legacy.workspaceId {
                    conversation.attachedWorkspaceIds.removeAll { $0 == workspaceId }
                    conversation.attachedWorkspaceIds.insert(workspaceId, at: 0)
                }
                if conversation.agentId == nil {
                    if let personaId = legacy.personaId {
                        conversation.agentId = personaId
                    } else if let slug = legacy.personaSlug {
                        if agentsBySlug[slug] == nil, let seed = PersonaCatalog.builtIn(id: slug) {
                            let id = UUID()
                            let agent = AgentModel(id: id, name: seed.name, instructions: seed.instructions,
                                                   vaultPath: AgentVaultPath.path(for: id), seedSlug: slug)
                            context.insert(agent)
                            agentsBySlug[slug] = agent
                        }
                        conversation.agentId = agentsBySlug[slug]?.id
                    }
                }
            }
            for payload in payloads { context.delete(payload) }
            try context.save()
        }
    )
}
