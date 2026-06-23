import Foundation
import PKShared
import PositronicKit
import SwiftData

extension AgentInstanceModel {
    convenience init(_ instance: AgentInstance) throws {
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(instance.metadata)
        } catch {
            throw PersistenceError.encoding("AgentInstance.metadata: \(error)")
        }
        self.init(
            id: instance.id,
            name: instance.name,
            instanceDescription: instance.description,
            primaryWorkspaceId: instance.primaryWorkspaceId,
            privateTimelineId: instance.privateTimelineId,
            lastActiveAt: instance.lastActiveAt,
            createdAt: instance.createdAt,
            updatedAt: instance.updatedAt,
            metadataData: metadataData
        )
    }

    func toAgentInstance() throws -> AgentInstance {
        let metadata: [String: AnyCodable]
        do {
            metadata = try JSONDecoder().decode([String: AnyCodable].self, from: metadataData)
        } catch {
            throw PersistenceError.decoding("AgentInstance.metadata: \(error)")
        }
        return AgentInstance(
            id: id,
            name: name,
            description: instanceDescription,
            primaryWorkspaceId: primaryWorkspaceId,
            privateTimelineId: privateTimelineId,
            lastActiveAt: lastActiveAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    func update(from instance: AgentInstance) throws {
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(instance.metadata)
        } catch {
            throw PersistenceError.encoding("AgentInstance.metadata: \(error)")
        }
        name = instance.name
        instanceDescription = instance.description
        primaryWorkspaceId = instance.primaryWorkspaceId
        lastActiveAt = instance.lastActiveAt
        updatedAt = instance.updatedAt
        self.metadataData = metadataData
    }
}

extension AgentTemplateModel {
    convenience init(_ template: AgentTemplate) throws {
        let seedData: Data?
        do {
            seedData = try template.workspaceFilesSeed.map { try JSONEncoder().encode($0) }
        } catch {
            throw PersistenceError.encoding("AgentTemplate.workspaceFilesSeed: \(error)")
        }
        self.init(
            id: template.id,
            name: template.name,
            templateDescription: template.description,
            systemPrompt: template.systemPrompt,
            personaPrompt: template.personaPrompt,
            guardrailsPrompt: template.guardrailsPrompt,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt,
            workspaceFilesSeedData: seedData
        )
    }

    func toAgentTemplate() throws -> AgentTemplate {
        let seed: [String: String]?
        do {
            seed = try workspaceFilesSeedData.map { try JSONDecoder().decode([String: String].self, from: $0) }
        } catch {
            throw PersistenceError.decoding("AgentTemplate.workspaceFilesSeed: \(error)")
        }
        return AgentTemplate(
            id: id,
            name: name,
            description: templateDescription,
            systemPrompt: systemPrompt,
            personaPrompt: personaPrompt,
            guardrailsPrompt: guardrailsPrompt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            workspaceFilesSeed: seed
        )
    }

    func update(from template: AgentTemplate) throws {
        let seedData: Data?
        do {
            seedData = try template.workspaceFilesSeed.map { try JSONEncoder().encode($0) }
        } catch {
            throw PersistenceError.encoding("AgentTemplate.workspaceFilesSeed: \(error)")
        }
        name = template.name
        templateDescription = template.description
        systemPrompt = template.systemPrompt
        personaPrompt = template.personaPrompt
        guardrailsPrompt = template.guardrailsPrompt
        updatedAt = template.updatedAt
        workspaceFilesSeedData = seedData
    }
}

/// `AgentInstanceStoreProtocol` adapter persisting `AgentInstance` values as
/// `AgentInstanceModel` rows. `fetchTimelines(attachedToAgent:)` queries
/// `TimelineModel.attachedAgentInstanceId` directly rather than maintaining a
/// separate join table.
@ModelActor
public actor SwiftDataAgentInstanceStore: AgentInstanceStoreProtocol {
    public func saveAgentInstance(_ instance: AgentInstance) async throws {
        let id = instance.id
        let descriptor = FetchDescriptor<AgentInstanceModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: instance)
        } else {
            try modelContext.insert(AgentInstanceModel(instance))
        }
        try modelContext.save()
    }

    public func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        var descriptor = FetchDescriptor<AgentInstanceModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        return try model.toAgentInstance()
    }

    public func fetchAllAgentInstances() async throws -> [AgentInstance] {
        let descriptor = FetchDescriptor<AgentInstanceModel>(sortBy: [SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).map { try $0.toAgentInstance() }
    }

    public func deleteAgentInstance(id: UUID) async throws {
        try modelContext.delete(model: AgentInstanceModel.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    public func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Timeline] {
        let descriptor = FetchDescriptor<TimelineModel>(
            predicate: #Predicate { $0.attachedAgentInstanceId == agentInstanceId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toTimeline() }
    }
}

/// `AgentTemplateStoreProtocol` adapter persisting `AgentTemplate` values as
/// `AgentTemplateModel` rows. `fetchAgentTemplate(key:)`/`hasAgentTemplate(id:)`
/// take `String` per the protocol (templates may be looked up by either the
/// UUID's string form or another stable key); this adapter matches against
/// `id.uuidString` since `AgentTemplate.id` is the only stable identifier on
/// the value type.
@ModelActor
public actor SwiftDataAgentTemplateStore: AgentTemplateStoreProtocol {
    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        let id = agent.id
        let descriptor = FetchDescriptor<AgentTemplateModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: agent)
        } else {
            try modelContext.insert(AgentTemplateModel(agent))
        }
        try modelContext.save()
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        var descriptor = FetchDescriptor<AgentTemplateModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        return try model.toAgentTemplate()
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        let descriptor = FetchDescriptor<AgentTemplateModel>()
        let models = try modelContext.fetch(descriptor)
        guard let model = models.first(where: { $0.id.uuidString == key }) else { return nil }
        return try model.toAgentTemplate()
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        let descriptor = FetchDescriptor<AgentTemplateModel>(sortBy: [SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).map { try $0.toAgentTemplate() }
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        let descriptor = FetchDescriptor<AgentTemplateModel>()
        guard let models = try? modelContext.fetch(descriptor) else { return false }
        return models.contains { $0.id.uuidString == id }
    }
}

/// Bundles one `@ModelActor` adapter per PositronicKit persistence protocol,
/// all sharing the same `ModelContainer` but each confining its own
/// `ModelContext` (per-actor, never shared — see `@ModelActor` docs on
/// `SwiftDataMessageStore`).
public struct YakamozStores: Sendable {
    public let messages: SwiftDataMessageStore
    public let timelines: SwiftDataTimelineStore
    public let workspaces: SwiftDataWorkspaceStore
    public let tools: SwiftDataToolStore
    public let agents: SwiftDataAgentInstanceStore
    public let templates: SwiftDataAgentTemplateStore
    public let origins: SwiftDataRequestOriginStore

    public init(modelContainer: ModelContainer) {
        messages = SwiftDataMessageStore(modelContainer: modelContainer)
        timelines = SwiftDataTimelineStore(modelContainer: modelContainer)
        workspaces = SwiftDataWorkspaceStore(modelContainer: modelContainer)
        tools = SwiftDataToolStore(modelContainer: modelContainer)
        agents = SwiftDataAgentInstanceStore(modelContainer: modelContainer)
        templates = SwiftDataAgentTemplateStore(modelContainer: modelContainer)
        origins = SwiftDataRequestOriginStore(modelContainer: modelContainer)
    }
}
