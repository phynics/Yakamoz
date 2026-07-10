import Foundation
import SwiftData

/// Performs the one-way persona-to-agent data migration while legacy persona fields
/// remain available to the UI. Safe to invoke on every application launch.
@MainActor
public enum AgentMigration {
    public static func seedAndMigrate(
        modelContext: ModelContext,
        vaultPath: (UUID) -> String = AgentVaultPath.path(for:)
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
            agentsBySeedSlug[persona.id] = agent
        }

        let personas = try modelContext.fetch(FetchDescriptor<PersonaModel>())
        let existingAgentIDs = Set(try modelContext.fetch(FetchDescriptor<AgentModel>()).map(\.id))
        for persona in personas where !persona.builtIn && !existingAgentIDs.contains(persona.id) {
            modelContext.insert(AgentModel(
                id: persona.id,
                name: persona.name,
                instructions: persona.systemInstructions,
                vaultPath: vaultPath(persona.id)
            ))
        }

        let conversations = try modelContext.fetch(FetchDescriptor<ConversationModel>())
        for conversation in conversations where conversation.agentId == nil {
            if let personaID = conversation.personaId,
               personas.contains(where: { $0.id == personaID && !$0.builtIn }) {
                conversation.agentId = personaID
            } else if let slug = conversation.personaSlug {
                conversation.agentId = agentsBySeedSlug[slug]?.id
            }
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
