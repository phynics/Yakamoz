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

        let vaultPath: (UUID) -> String = { id in "/tmp/\(id)" }
        try AgentMigration.seedAndMigrate(modelContext: container.mainContext, vaultPath: vaultPath)
        try AgentMigration.seedAndMigrate(modelContext: container.mainContext, vaultPath: vaultPath)

        let agents = try container.mainContext.fetch(FetchDescriptor<AgentModel>())
        #expect(agents.count == PersonaCatalog.builtIns.count)
        for persona in PersonaCatalog.builtIns {
            let agent = try #require(agents.first { $0.seedSlug == persona.id })
            #expect(agent.name == persona.name)
            #expect(agent.instructions == persona.instructions)
            #expect(agent.vaultPath == vaultPath(agent.id))
        }
    }

    @Test("Migration preserves custom identity and maps built-in conversation")
    @MainActor
    func migratesPersonasAndConversationReferences() throws {
        let container = try makeContainer()
        let customPersona = PersonaModel(name: "Custom", systemInstructions: "Use diagrams.")
        let customPersonaID = customPersona.id
        let customConversation = ConversationModel(title: "Custom", personaId: customPersonaID)
        let builtInConversation = ConversationModel(title: "Built in", personaSlug: "reviewer")
        container.mainContext.insert(customPersona)
        container.mainContext.insert(customConversation)
        container.mainContext.insert(builtInConversation)
        try container.mainContext.save()

        try AgentMigration.seedAndMigrate(modelContext: container.mainContext, vaultPath: { id in "/tmp/\(id)" })

        let customAgent = try #require(try container.mainContext.fetch(FetchDescriptor<AgentModel>(predicate: #Predicate { $0.id == customPersonaID })).first)
        #expect(customAgent.name == "Custom")
        #expect(customAgent.instructions == "Use diagrams.")
        #expect(customConversation.agentId == customPersonaID)

        let reviewer = try #require(try container.mainContext.fetch(FetchDescriptor<AgentModel>(predicate: #Predicate { $0.seedSlug == "reviewer" })).first)
        #expect(builtInConversation.agentId == reviewer.id)
    }
}
