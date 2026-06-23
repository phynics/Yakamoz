import Foundation
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// Exercises `ConversationCoordinator` and `YakamozRuntime.createConversation`: the
/// integration point that pairs one `ConversationModel` row with a PositronicKit
/// `Timeline` sharing the same `id`, so `ChatViewModel`/`ChatEngine.run(timelineId:)`
/// can address the conversation `ConversationListView` displays (Task 7).
@Suite("ConversationCoordinator")
@MainActor
struct ConversationCoordinatorTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(YakamozSchema.models), configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test("createConversation inserts a ConversationModel and a Timeline sharing the same id")
    func createsPairedConversationAndTimeline() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )

        let conversation = try await coordinator.createConversation(title: "Hello World")

        #expect(conversation.title == "Hello World")

        let timeline = try await stores.timelines.fetchTimeline(id: conversation.id)
        #expect(timeline != nil)
        #expect(timeline?.id == conversation.id)
        #expect(timeline?.title == "Hello World")
    }

    @Test("createConversation propagates personaId and workspaceId onto the ConversationModel")
    func propagatesOptionalAssociations() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let personaId = UUID()
        let workspaceId = UUID()

        let conversation = try await coordinator.createConversation(
            title: "Scoped Chat",
            personaId: personaId,
            workspaceId: workspaceId
        )

        #expect(conversation.personaId == personaId)
        #expect(conversation.workspaceId == workspaceId)
    }

    @Test("YakamozRuntime.createConversation delegates to the same pairing logic")
    func runtimeCreateConversationPairsTimeline() async throws {
        let container = try makeContainer()
        let defaults = try #require(UserDefaults(suiteName: "ConversationCoordinatorTests.\(UUID().uuidString)"))
        let settings = ProviderSettings(defaults: defaults)
        let secrets = FakeSecretStore()
        let mock = MockLLMService()

        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock }
        )

        let conversation = try await runtime.createConversation(
            modelContext: container.mainContext,
            title: "Runtime Chat"
        )

        let timeline = try await runtime.stores.timelines.fetchTimeline(id: conversation.id)
        #expect(timeline?.id == conversation.id)
        #expect(timeline?.title == "Runtime Chat")
    }
}
