import Foundation
import SwiftData

/// Performs the one-way persona-to-agent data migration while legacy persona fields
/// remain available to the UI. Safe to invoke on every application launch.
@MainActor
public enum AgentMigration {
    public static func seedAndMigrate(
        modelContext: ModelContext,
        vaultPath: (UUID) -> String = AgentVaultPath.path(for:),
        vaultFactory: AgentVaultFactory = AgentVaultFactory()
    ) throws {
        let agents = try modelContext.fetch(FetchDescriptor<AgentModel>())
        var agentsBySeedSlug = Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            agent.seedSlug.map { ($0, agent) }
        })

        for persona in PersonaCatalog.builtIns where agentsBySeedSlug[persona.id] == nil {
            let id = UUID()
            let agent = AgentModel(
                id: id,
                name: persona.name,
                instructions: persona.instructions,
                vaultPath: vaultPath(id),
                seedSlug: persona.id
            )
            modelContext.insert(agent)
            try vaultFactory.createVault(for: agent)
            agentsBySeedSlug[persona.id] = agent
        }

        let personas = try modelContext.fetch(FetchDescriptor<PersonaModel>())
        let existingAgentIDs = try Set(modelContext.fetch(FetchDescriptor<AgentModel>()).map(\.id))
        for persona in personas where !persona.builtIn && !existingAgentIDs.contains(persona.id) {
            let agent = AgentModel(
                id: persona.id,
                name: persona.name,
                instructions: persona.systemInstructions,
                vaultPath: vaultPath(persona.id)
            )
            modelContext.insert(agent)
            try vaultFactory.createVault(for: agent)
        }

        // A schema migration may have created a seeded agent before the runtime's normal
        // seeding pass. Ensure those already-persisted agents receive the same idempotent
        // vault initialization as newly created rows.
        for agent in try modelContext.fetch(FetchDescriptor<AgentModel>()) {
            try vaultFactory.createVault(for: agent)
        }

        try modelContext.save()
    }
}

public enum AgentVaultPath {
    public static func path(for agentID: UUID) -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: "Yakamoz/Agents/\(agentID.uuidString)", directoryHint: .isDirectory).path
    }
}
