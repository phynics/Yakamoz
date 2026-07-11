import Foundation
import SwiftData
import Testing
@testable import YakamozCore

@Suite("AgentModel migration")
struct AgentModelMigrationTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(YakamozSchema.models),
            configurations: .init(isStoredInMemoryOnly: true)
        )
    }

    @Test("Agent store saves fetches and deletes agents")
    @MainActor
    func agentStoreCRUD() throws {
        let container = try makeContainer()
        let store = SwiftDataAgentStore(modelContainer: container)
        let agent = AgentModel(name: "Ada", instructions: "Be precise.", vaultPath: "/tmp/ada")

        try store.saveAgent(agent)
        #expect(try store.fetchAgent(id: agent.id)?.name == "Ada")
        #expect(try store.fetchAllAgents().map(\.id) == [agent.id])

        try store.deleteAgent(id: agent.id)
        #expect(try store.fetchAgent(id: agent.id) == nil)
    }

    @Test("Seeding built-ins is idempotent")
    @MainActor
    func seedBuiltInsIdempotently() throws {
        let container = try makeContainer()
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let vaultFactory = AgentVaultFactory(baseDirectory: tempRoot)

        let vaultPath: (UUID) -> String = { id in "/tmp/\(id)" }
        try AgentMigration.seedAndMigrate(modelContext: container.mainContext, vaultPath: vaultPath, vaultFactory: vaultFactory)
        try AgentMigration.seedAndMigrate(modelContext: container.mainContext, vaultPath: vaultPath, vaultFactory: vaultFactory)

        let agents = try container.mainContext.fetch(FetchDescriptor<AgentModel>())
        #expect(agents.count == PersonaCatalog.builtIns.count)
        for persona in PersonaCatalog.builtIns {
            let agent = try #require(agents.first { $0.seedSlug == persona.id })
            #expect(agent.name == persona.name)
            #expect(agent.instructions == persona.instructions)
            #expect(agent.vaultPath == vaultPath(agent.id))
        }
    }

    @Test("Seeding repairs the vault for an already-migrated built-in agent")
    @MainActor
    func seedBuiltInsRepairsExistingAgentVault() throws {
        let container = try makeContainer()
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let vaultFactory = AgentVaultFactory(baseDirectory: tempRoot)
        let reviewer = try #require(PersonaCatalog.builtIn(id: "reviewer"))
        let id = UUID()
        let agent = AgentModel(
            id: id,
            name: reviewer.name,
            instructions: reviewer.instructions,
            vaultPath: vaultFactory.vaultRoot(for: id).path,
            seedSlug: reviewer.id
        )
        container.mainContext.insert(agent)
        try container.mainContext.save()

        try AgentMigration.seedAndMigrate(
            modelContext: container.mainContext,
            vaultPath: { agentID in vaultFactory.vaultRoot(for: agentID).path },
            vaultFactory: vaultFactory
        )

        #expect(FileManager.default.fileExists(atPath: agent.vaultPath))
        #expect(FileManager.default.fileExists(atPath: URL(filePath: agent.vaultPath).appending(path: "WORKFLOW.md").path))
    }

    @Test("Versioned schema migration preserves legacy operator and workspace references")
    @MainActor
    func migratesPersonasAndConversationReferences() throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "YakamozMigration-\(UUID()).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let customPersonaID = UUID()
        let legacyWorkspaceID = UUID()
        do {
            let schema = Schema(versionedSchema: YakamozSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
            container.mainContext.insert(YakamozSchemaV1.ConversationModel(
                title: "Legacy", personaId: customPersonaID, workspaceId: legacyWorkspaceID,
                attachedWorkspaceIds: [UUID()]
            ))
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: YakamozSchemaV2.self)
        let migrated = try ModelContainer(for: schema, migrationPlan: YakamozMigrationPlan.self,
                                          configurations: ModelConfiguration(schema: schema, url: storeURL))
        let conversation = try #require(try migrated.mainContext.fetch(FetchDescriptor<ConversationModel>()).first)
        #expect(conversation.agentId == customPersonaID)
        #expect(conversation.attachedWorkspaceIds.first == legacyWorkspaceID)
    }

    @Test("Versioned migration seeds and resolves a built-in persona slug")
    @MainActor
    func migratesBuiltInSlugWithoutExistingAgents() throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "YakamozSlugMigration-\(UUID()).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        do {
            let schema = Schema(versionedSchema: YakamozSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
            container.mainContext.insert(YakamozSchemaV1.ConversationModel(title: "Review", personaSlug: "reviewer"))
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: YakamozSchemaV2.self)
        let migrated = try ModelContainer(for: schema, migrationPlan: YakamozMigrationPlan.self,
                                          configurations: ModelConfiguration(schema: schema, url: storeURL))
        let reviewer = try #require(try migrated.mainContext.fetch(
            FetchDescriptor<AgentModel>(predicate: #Predicate { $0.seedSlug == "reviewer" })
        ).first)
        let conversation = try #require(try migrated.mainContext.fetch(FetchDescriptor<ConversationModel>()).first)
        #expect(conversation.agentId == reviewer.id)
        #expect(reviewer.name == "Terse Code Reviewer")
    }
}
