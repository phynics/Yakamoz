import Foundation
import PKShared
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

    @Test("applyTitleDirective updates title and resets cadence counters on a value outcome")
    func applyTitleDirectiveUpdatesOnValue() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(name: "title", outcome: .value(AnyCodable("Fixing the auth bug")))
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "Fixing the auth bug")
        #expect(fetched.hasReceivedTitleDirective == true)
        #expect(fetched.turnsSinceLastTitleDirective == 0)
    }

    @Test("applyTitleDirective is a no-op on a declined outcome, but still advances the cadence counter")
    func applyTitleDirectiveNoOpOnDecline() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(name: "title", outcome: .declined)
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "New Chat")
        #expect(fetched.turnsSinceLastTitleDirective == 1)
    }

    @Test("applyTitleDirective no-ops for directive names it does not own")
    func applyTitleDirectiveIgnoresUnownedDirectiveNames() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(name: "section_title", outcome: .value(AnyCodable("Section")))
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "New Chat")
        #expect(fetched.turnsSinceLastTitleDirective == 0)
    }

    @Test("applyTitleDirective no-ops silently when the conversation cannot be found")
    func applyTitleDirectiveNoOpsForMissingConversation() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        // A stale/cancelled turn racing conversation deletion must not throw — the
        // caller's post-turn hook cannot recovery from a missing row, so it is
        // intentionally swallowed.
        try await coordinator.applyTitleDirective(
            conversationId: UUID(),
            result: SidecarResult(name: "title", outcome: .value(AnyCodable("Late Title")))
        )
    }

    @Test("recordSectionTitleAnnotation inserts a row only on a non-null value result")
    func recordSectionTitleAnnotationInsertsOnValue() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 2,
            result: SidecarResult(name: "section_title", outcome: .value(AnyCodable("Exploring the bug")))
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "Exploring the bug")
        #expect(fetched.first?.turnIndex == 2)
        #expect(fetched.first?.kind == .sectionTitle)
    }

    @Test("recordSectionTitleAnnotation no-ops on a declined result (no row inserted)")
    func recordSectionTitleAnnotationNoOpsOnDecline() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 0,
            result: SidecarResult(name: "section_title", outcome: .declined)
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.isEmpty)
    }

    @Test("recordSectionTitleAnnotation no-ops on a failed result (no row inserted)")
    func recordSectionTitleAnnotationNoOpsOnFailure() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 0,
            result: SidecarResult(name: "section_title", outcome: .failed(reason: "schema mismatch"))
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.isEmpty)
    }

    @Test("recordSectionTitleAnnotation no-ops for directive names it does not own")
    func recordSectionTitleAnnotationIgnoresUnownedDirectiveNames() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 0,
            result: SidecarResult(name: "title", outcome: .value(AnyCodable("A Title")))
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.isEmpty)
    }

    @Test("fetchLatestSectionTitle returns the highest-turnIndex annotation's text")
    func fetchLatestSectionTitleReturnsHighestTurnIndex() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 2,
            result: SidecarResult(name: "section_title", outcome: .value(AnyCodable("Exploring")))
        )
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 7,
            result: SidecarResult(name: "section_title", outcome: .value(AnyCodable("Implementing")))
        )

        let latest = try coordinator.fetchLatestSectionTitle(conversationId: conversationId)
        #expect(latest == "Implementing")
    }

    @Test("fetchLatestSectionTitle returns nil when no annotations exist")
    func fetchLatestSectionTitleReturnsNilWhenEmpty() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")

        let latest = try coordinator.fetchLatestSectionTitle(conversationId: conversation.id)
        #expect(latest == nil)
    }
}
