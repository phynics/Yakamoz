import Foundation
import Logging
import PKContracts
import PositronicKit
import SwiftData

/// SwiftData CRUD for Yakamoz's persistent agent rows. This deliberately stays
/// separate from `SwiftDataAgentInstanceStore`, which adapts PositronicKit's runtime
/// `AgentInstance` protocol model.
@MainActor
public final class SwiftDataAgentStore {
    private let modelContext: ModelContext

    public init(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
    }

    /// Builds a store over an already selected main-actor context. This is useful for
    /// coordinators that share a context with their SwiftData UI models.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func saveAgent(_ agent: AgentModel) throws {
        let id = agent.id
        let descriptor = FetchDescriptor<AgentModel>(predicate: #Predicate { $0.id == id })
        let existing = try modelContext.fetch(descriptor).first
        if let existing, existing !== agent {
            existing.name = agent.name
            existing.instructions = agent.instructions
            existing.vaultPath = agent.vaultPath
            existing.homeTimelineId = agent.homeTimelineId
            existing.seedSlug = agent.seedSlug
            existing.defaultModel = agent.defaultModel
            existing.defaultEnabledToolIds = agent.defaultEnabledToolIds
            existing.createdAt = agent.createdAt
        } else if existing == nil {
            modelContext.insert(agent)
        }
        try modelContext.save()
    }

    public func fetchAgent(id: UUID) throws -> AgentModel? {
        var descriptor = FetchDescriptor<AgentModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public func fetchAllAgents() throws -> [AgentModel] {
        try modelContext.fetch(FetchDescriptor<AgentModel>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    public func deleteAgent(id: UUID) throws {
        try modelContext.delete(model: AgentModel.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }
}

extension AgentInstanceModel {
    convenience init(_ agent: Agent) throws {
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(agent.metadata)
        } catch {
            throw PersistenceError.encoding("Agent.metadata: \(error)")
        }
        self.init(
            id: agent.id,
            name: agent.name,
            instanceDescription: agent.description,
            lifecycle: agent.lifecycle,
            primaryWorkspaceId: agent.primaryWorkspaceID,
            privateTimelineId: agent.privateThreadID,
            lastActiveAt: agent.lastActiveAt,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt,
            metadataData: metadataData
        )
    }

    func toAgent() throws -> Agent {
        let metadata: [String: AnyCodable]
        do {
            metadata = try JSONDecoder().decode([String: AnyCodable].self, from: metadataData)
        } catch {
            throw PersistenceError.decoding("Agent.metadata: \(error)")
        }
        return Agent(
            id: id,
            name: name,
            description: instanceDescription,
            lifecycle: AgentLifecycleState(rawValue: lifecycleRaw) ?? .active,
            primaryWorkspaceID: primaryWorkspaceId,
            privateThreadID: privateTimelineId,
            lastActiveAt: lastActiveAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    func update(from agent: Agent) throws {
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(agent.metadata)
        } catch {
            throw PersistenceError.encoding("Agent.metadata: \(error)")
        }
        name = agent.name
        instanceDescription = agent.description
        lifecycleRaw = agent.lifecycle.rawValue
        primaryWorkspaceId = agent.primaryWorkspaceID
        lastActiveAt = agent.lastActiveAt
        updatedAt = agent.updatedAt
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
public actor SwiftDataAgentInstanceStore: AgentStoreProtocol {
    public nonisolated let isDurable = true

    public func saveAgent(_ agent: Agent) async throws {
        let id = agent.id
        let descriptor = FetchDescriptor<AgentInstanceModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: agent)
        } else {
            try modelContext.insert(AgentInstanceModel(agent))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save Agent", metadata: [
                "store": "AgentInstanceStore",
                "agentID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAgent(id: UUID) async throws -> Agent? {
        var descriptor = FetchDescriptor<AgentInstanceModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            guard let model = try modelContext.fetch(descriptor).first else { return nil }
            return try model.toAgent()
        } catch {
            Log.runtime.warning("failed to fetch Agent", metadata: [
                "store": "AgentInstanceStore",
                "agentID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAllAgents() async throws -> [Agent] {
        let descriptor = FetchDescriptor<AgentInstanceModel>(sortBy: [SortDescriptor(\.createdAt)])
        do {
            return try modelContext.fetch(descriptor).map { try $0.toAgent() }
        } catch {
            Log.runtime.warning("failed to fetch all Agents", metadata: [
                "store": "AgentInstanceStore",
            ])
            throw error
        }
    }

    public func deleteAgent(id: UUID) async throws {
        try modelContext.delete(model: AgentInstanceModel.self, where: #Predicate { $0.id == id })
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to delete Agent", metadata: [
                "store": "AgentInstanceStore",
                "agentID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchThreads(attachedToAgent agentId: UUID) async throws -> [YakamozThread] {
        let descriptor = FetchDescriptor<TimelineModel>(
            predicate: #Predicate { $0.attachedAgentInstanceId == agentId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            return try modelContext.fetch(descriptor).map { try $0.toThread() }
        } catch {
            Log.runtime.warning("failed to fetch Threads for Agent", metadata: [
                "store": "AgentInstanceStore",
                "agentID": "\(agentId)",
            ])
            throw error
        }
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
    public nonisolated let isDurable = true

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        let id = agent.id
        let descriptor = FetchDescriptor<AgentTemplateModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: agent)
        } else {
            try modelContext.insert(AgentTemplateModel(agent))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save AgentTemplate", metadata: [
                "store": "AgentTemplateStore",
                "templateID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        var descriptor = FetchDescriptor<AgentTemplateModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            guard let model = try modelContext.fetch(descriptor).first else { return nil }
            return try model.toAgentTemplate()
        } catch {
            Log.runtime.warning("failed to fetch AgentTemplate", metadata: [
                "store": "AgentTemplateStore",
                "templateID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        let descriptor = FetchDescriptor<AgentTemplateModel>()
        do {
            let models = try modelContext.fetch(descriptor)
            guard let model = models.first(where: { $0.id.uuidString == key }) else { return nil }
            return try model.toAgentTemplate()
        } catch {
            Log.runtime.warning("failed to fetch AgentTemplate by key", metadata: [
                "store": .string("AgentTemplateStore"),
                "key": .string(key),
            ])
            throw error
        }
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        let descriptor = FetchDescriptor<AgentTemplateModel>(sortBy: [SortDescriptor(\.createdAt)])
        do {
            return try modelContext.fetch(descriptor).map { try $0.toAgentTemplate() }
        } catch {
            Log.runtime.warning("failed to fetch all AgentTemplates", metadata: [
                "store": "AgentTemplateStore",
            ])
            throw error
        }
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        let descriptor = FetchDescriptor<AgentTemplateModel>()
        guard let models = try? modelContext.fetch(descriptor) else {
            Log.runtime.warning("failed to fetch AgentTemplates for hasAgentTemplate check", metadata: [
                "store": .string("AgentTemplateStore"),
                "templateID": .string(id),
            ])
            return false
        }
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
