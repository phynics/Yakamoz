import Foundation
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("Home timelines")
@MainActor
struct HomeTimelineTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(YakamozSchema.models), configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeRuntime(in container: ModelContainer) throws -> YakamozRuntime {
        let defaults = try #require(UserDefaults(suiteName: "HomeTimelineTests.\(UUID())"))
        return try YakamozRuntime(
            modelContainer: container,
            settings: ProviderSettings(defaults: defaults),
            secrets: FakeSecretStore(),
            llmServiceFactory: { _ in MockLLMService() }
        )
    }

    @Test("home timeline is lazily created once and scoped only to its agent vault")
    func createsAndReusesHomeTimeline() async throws {
        let container = try makeContainer()
        let runtime = try makeRuntime(in: container)
        let agent = AgentModel(name: "Ada", instructions: "Help.", vaultPath: "/tmp/ada")
        container.mainContext.insert(agent)
        try container.mainContext.save()

        let first = try await runtime.homeTimeline(for: agent.id, modelContext: container.mainContext)
        let second = try await runtime.homeTimeline(for: agent.id, modelContext: container.mainContext)

        #expect(first.id == second.id)
        #expect(agent.homeTimelineId == first.id)
        #expect(first.isHomeTimeline)
        #expect(first.agentId == agent.id)
        #expect(first.attachedWorkspaceIds.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ConversationModel>()).count == 1)
    }

    @Test("missing stored home timeline is repaired")
    func repairsMissingHomeTimeline() async throws {
        let container = try makeContainer()
        let runtime = try makeRuntime(in: container)
        let missingID = UUID()
        let agent = AgentModel(name: "Ada", instructions: "Help.", vaultPath: "/tmp/ada", homeTimelineId: missingID)
        container.mainContext.insert(agent)
        try container.mainContext.save()

        let repaired = try await runtime.homeTimeline(for: agent.id, modelContext: container.mainContext)

        #expect(repaired.id != missingID)
        #expect(agent.homeTimelineId == repaired.id)
        #expect(repaired.isHomeTimeline)
        #expect(repaired.agentId == agent.id)
    }

    @Test("malformed stored home timeline is repaired rather than reused")
    func repairsMalformedHomeTimeline() async throws {
        let container = try makeContainer()
        let runtime = try makeRuntime(in: container)
        let agent = AgentModel(name: "Ada", instructions: "Help.", vaultPath: "/tmp/ada")
        let malformed = ConversationModel(title: "Task", isHomeTimeline: false)
        agent.homeTimelineId = malformed.id
        container.mainContext.insert(agent)
        container.mainContext.insert(malformed)
        try container.mainContext.save()

        let repaired = try await runtime.homeTimeline(for: agent.id, modelContext: container.mainContext)

        #expect(repaired.id != malformed.id)
        #expect(repaired.isHomeTimeline)
        #expect(repaired.agentId == agent.id)
        #expect(agent.homeTimelineId == repaired.id)
    }

    @Test("standard list query excludes home timelines at fetch time")
    func standardListQueryExcludesHomeTimelines() throws {
        let container = try makeContainer()
        let standard = ConversationModel(title: "Task")
        let home = ConversationModel(title: "Home", isHomeTimeline: true)
        container.mainContext.insert(standard)
        container.mainContext.insert(home)
        try container.mainContext.save()

        let listed = try container.mainContext.fetch(ConversationListQuery.descriptor)

        #expect(listed.map(\.id) == [standard.id])
    }

    @Test("ordinary deletion refuses a home timeline")
    func ordinaryDeletionRefusesHomeTimeline() throws {
        let container = try makeContainer()
        let home = ConversationModel(title: "Home", isHomeTimeline: true)
        container.mainContext.insert(home)
        try container.mainContext.save()

        let pruned = WorkspaceAttachmentSupport.deleteConversation(home, modelContext: container.mainContext)

        #expect(pruned.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ConversationModel>()).map(\.id) == [home.id])
    }

    @Test("deleting an agent removes its home timeline and vault")
    func deletingAgentRemovesHomeTimelineAndVault() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let vaults = AgentVaultFactory(baseDirectory: root)
        let agent = AgentModel(name: "Ada", instructions: "Help.", vaultPath: "")
        container.mainContext.insert(agent)
        try vaults.createVault(for: agent)
        try container.mainContext.save()
        let coordinator = ConversationCoordinator(modelContext: container.mainContext, timelineStore: stores.timelines, vaultFactory: vaults)
        let home = try await coordinator.homeTimeline(for: agent.id)

        try await coordinator.deleteAgent(id: agent.id)

        #expect(try container.mainContext.fetch(FetchDescriptor<AgentModel>()).contains(where: { $0.id == agent.id }) == false)
        #expect(try container.mainContext.fetch(FetchDescriptor<ConversationModel>()).isEmpty)
        #expect(try await stores.timelines.fetchTimeline(id: home.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: vaults.vaultRoot(for: agent.id).path))
    }

    @Test("runtime exposes confirmed agent deletion cascade")
    func runtimeDeletesAgentResources() async throws {
        let container = try makeContainer()
        let runtime = try makeRuntime(in: container)
        let agent = AgentModel(name: "Ada", instructions: "Help.", vaultPath: "/tmp/ada")
        container.mainContext.insert(agent)
        try container.mainContext.save()
        let home = try await runtime.homeTimeline(for: agent.id, modelContext: container.mainContext)

        try await runtime.deleteAgent(id: agent.id, modelContext: container.mainContext)

        #expect(try container.mainContext.fetch(FetchDescriptor<AgentModel>()).contains(where: { $0.id == agent.id }) == false)
        #expect(try container.mainContext.fetch(FetchDescriptor<ConversationModel>()).map(\.id).contains(home.id) == false)
    }
}
