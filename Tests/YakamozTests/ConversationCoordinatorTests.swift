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

    @Test("createConversation propagates agent and workspace associations")
    func propagatesOptionalAssociations() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let agent = AgentModel(name: "Ada", instructions: "A", vaultPath: "/tmp/a")
        container.mainContext.insert(agent)
        try container.mainContext.save()
        let workspaceId = UUID()

        let conversation = try await coordinator.createConversation(
            title: "Scoped Chat",
            agentId: agent.id,
            attachedWorkspaceIds: [workspaceId]
        )

        #expect(conversation.agentId == agent.id)
        #expect(conversation.attachedWorkspaceIds == [workspaceId])
        #expect(agent.backendInstanceId == agent.id)
        let templates = try container.mainContext.fetch(FetchDescriptor<AgentTemplateModel>())
        #expect(templates.first(where: { $0.id == agent.id })?.systemPrompt == agent.instructions)
        let timeline = try #require(await stores.timelines.fetchTimeline(id: conversation.id))
        #expect(timeline.attachedAgentInstanceId == agent.id)
    }

    @Test("operator swap updates the agent and appends one named system marker")
    func operatorSwapPersistsHandoffMarker() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let first = AgentModel(name: "Ada", instructions: "A", vaultPath: "/tmp/a")
        let second = AgentModel(name: "Grace", instructions: "B", vaultPath: "/tmp/b")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "Swap", agentId: first.id)
        container.mainContext.insert(MessageModel(conversationId: conversation.id, role: "user", content: "existing"))
        try container.mainContext.save()

        try await coordinator.setOperator(conversationId: conversation.id, agentId: second.id)

        #expect(conversation.agentId == second.id)
        let messages = try await stores.messages.fetchMessages(for: conversation.id)
        #expect(messages.count == 2)
        #expect(messages.first?.content == "existing")
        #expect(messages.last?.role == "system")
        #expect(messages.last?.content == "Operator changed: Ada → Grace")
        #expect(first.backendInstanceId == first.id)
        #expect(second.backendInstanceId == second.id)
        let timeline = try #require(await stores.timelines.fetchTimeline(id: conversation.id))
        #expect(timeline.attachedAgentInstanceId == second.id)
    }

    @Test("createConversation persists workspace order and home timeline flag")
    func persistsWorkspaceOrderAndHomeFlag() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(modelContext: container.mainContext, timelineStore: stores.timelines)
        let ids = [UUID(), UUID()]

        let conversation = try await coordinator.createConversation(
            attachedWorkspaceIds: ids,
            isHomeTimeline: true
        )

        #expect(conversation.attachedWorkspaceIds == ids)
        #expect(conversation.isHomeTimeline)
        #expect(try await stores.timelines.fetchTimeline(id: conversation.id)?.attachedWorkspaceIds == ids)
    }

    @Test("operator transitions to and from none each append exactly one marker")
    func nilOperatorTransitions() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let agent = AgentModel(name: "Ada", instructions: "A", vaultPath: "/tmp/a")
        container.mainContext.insert(agent)
        try container.mainContext.save()
        let coordinator = ConversationCoordinator(modelContext: container.mainContext, timelineStore: stores.timelines)
        let conversation = try await coordinator.createConversation()
        try await coordinator.setOperator(conversationId: conversation.id, agentId: agent.id)
        try await coordinator.setOperator(conversationId: conversation.id, agentId: nil)
        let messages = try await stores.messages.fetchMessages(for: conversation.id)
        #expect(messages.map(\.content) == ["Operator changed: none → Ada", "Operator changed: Ada → none"])
    }

    @Test("home timeline operator cannot be swapped")
    func homeOperatorIsFixed() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(modelContext: container.mainContext, timelineStore: stores.timelines)
        let conversation = try await coordinator.createConversation(isHomeTimeline: true)
        await #expect(throws: ConversationCoordinator.OperatorError.homeTimelineOperatorIsFixed) {
            try await coordinator.setOperator(conversationId: conversation.id, agentId: nil)
        }
    }

    @Test("standard conversation query excludes home timelines")
    func standardQueryExcludesHomes() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(modelContext: container.mainContext, timelineStore: stores.timelines)
        let standard = try await coordinator.createConversation(title: "Standard")
        _ = try await coordinator.createConversation(title: "Home", isHomeTimeline: true)
        #expect(try coordinator.fetchStandardConversations().map(\.id) == [standard.id])
    }

    @Test("runtime refuses to run an unassigned conversation")
    func unassignedRunThrows() async throws {
        let container = try makeContainer()
        let defaults = try #require(UserDefaults(suiteName: "ConversationCoordinatorTests.\(UUID())"))
        let runtime = try YakamozRuntime(modelContainer: container, settings: ProviderSettings(defaults: defaults), secrets: FakeSecretStore(), llmServiceFactory: { _ in MockLLMService() })
        let conversation = try await runtime.createConversation(modelContext: container.mainContext)
        await #expect(throws: ConversationRunError.operatorRequired) {
            _ = try await runtime.run(ChatRunRequest(timelineId: conversation.id, message: "hello", tools: []))
        }
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

        // SID-3: the runtime emits the per-directive payload sub-object
        // (`TitleDirectivePayload`'s encoded form `{"title": "..."}`), not a bare
        // string. The previous bare-`AnyCodable("...")` fixture never matched the
        // runtime shape and so was false-green.
        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(
                name: "title",
                outcome: .value(AnyCodable.dictionary(["title": .string("Fixing the auth bug")]))
            )
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "Fixing the auth bug")
        #expect(fetched.hasReceivedTitleDirective == true)
        #expect(fetched.turnsSinceLastTitleDirective == 0)
    }

    @Test("applyTitleDirective recovers the title from an off-schema single-string dict")
    func applyTitleDirectiveRecoversOffSchema() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        // SID-3: providers sometimes freelance the key (e.g. `text` instead of `title`).
        // The recover path takes the dict's only non-empty string so the title still lands.
        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(
                name: "title",
                outcome: .value(AnyCodable.dictionary(["text": .string("Riemann Conjecture Overview")]))
            )
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "Riemann Conjecture Overview")
        #expect(fetched.hasReceivedTitleDirective == true)
        #expect(fetched.turnsSinceLastTitleDirective == 0)
    }

    @Test("applyTitleDirective leaves the title untouched but advances the cadence counter for an unextractable payload")
    func applyTitleDirectiveAdvancesCounterOnUnextractable() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        // SID-3: a `.value` carrying a non-empty dict with no extractable non-empty
        // string (here an explicit `null` value) routes to the recover-but-empty path:
        // title untouched, cadence counter still advances (the turn happened).
        try await coordinator.applyTitleDirective(
            conversationId: conversationId,
            result: SidecarResult(
                name: "title",
                outcome: .value(AnyCodable.dictionary(["title": .null]))
            )
        )

        let fetched = try #require(try container.mainContext.fetch(
            FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == conversationId })
        ).first)
        #expect(fetched.title == "New Chat")
        #expect(fetched.hasReceivedTitleDirective == false)
        #expect(fetched.turnsSinceLastTitleDirective == 1)
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

        // SID-3: runtime emits the per-directive payload sub-object
        // (`SectionTitleDirectivePayload`'s encoded form `{"sectionTitle": "..."}`,
        // camelCase JSON key — distinct from the directive's snake_case `name`).
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 2,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Exploring the bug")]))
            )
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "Exploring the bug")
        #expect(fetched.first?.turnIndex == 2)
        #expect(fetched.first?.kind == .sectionTitle)
    }

    @Test("recordSectionTitleAnnotation recovers from an off-schema single-string dict")
    func recordSectionTitleAnnotationRecoversOffSchema() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        // SID-3: off-schema recover — provider freelanced the key
        // (`{"text": "..."}` instead of `{"sectionTitle": "..."}`).
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 3,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["text": .string("Implementing the fix")]))
            )
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "Implementing the fix")
        #expect(fetched.first?.turnIndex == 3)
    }

    @Test("recordSectionTitleAnnotation no-ops on an unextractable dict (no row inserted)")
    func recordSectionTitleAnnotationNoOpsOnUnextractable() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        // SID-3: empty dict — neither the expected key nor a single-string recover
        // candidate is present; nothing extractable, no row inserted.
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 0,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary([:]))
            )
        )

        let fetched = try container.mainContext.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        ))
        #expect(fetched.isEmpty)
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
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Exploring")]))
            )
        )
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 7,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Implementing")]))
            )
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

    @Test("fetchSectionAnnotations returns section-title annotations in turn order")
    func fetchSectionAnnotationsReturnsInTurnOrder() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")
        let conversationId = conversation.id

        // Insert out of turn order to prove the fetch sorts rather than relying on
        // insertion order.
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 7,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Implementing the fix")]))
            )
        )
        try coordinator.recordSectionTitleAnnotation(
            conversationId: conversationId,
            turnIndex: 2,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Exploring the bug")]))
            )
        )

        let annotations = try coordinator.fetchSectionAnnotations(conversationId: conversationId)
        #expect(annotations.map(\.text) == ["Exploring the bug", "Implementing the fix"])
        #expect(annotations.map(\.turnIndex) == [2, 7])
    }

    @Test("fetchSectionAnnotations returns empty when the conversation has none")
    func fetchSectionAnnotationsReturnsEmptyWhenNone() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let conversation = try await coordinator.createConversation(title: "New Chat")

        let annotations = try coordinator.fetchSectionAnnotations(conversationId: conversation.id)
        #expect(annotations.isEmpty)
    }

    @Test("fetchSectionAnnotations is scoped by conversationId")
    func fetchSectionAnnotationsScopedByConversationId() async throws {
        let container = try makeContainer()
        let stores = YakamozStores(modelContainer: container)
        let coordinator = ConversationCoordinator(
            modelContext: container.mainContext,
            timelineStore: stores.timelines
        )
        let a = try await coordinator.createConversation(title: "A")
        let b = try await coordinator.createConversation(title: "B")

        try coordinator.recordSectionTitleAnnotation(
            conversationId: a.id,
            turnIndex: 0,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("A1")]))
            )
        )
        try coordinator.recordSectionTitleAnnotation(
            conversationId: b.id,
            turnIndex: 0,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("B1")]))
            )
        )
        try coordinator.recordSectionTitleAnnotation(
            conversationId: a.id,
            turnIndex: 3,
            result: SidecarResult(
                name: "section_title",
                outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("A2")]))
            )
        )

        let aAnnotations = try coordinator.fetchSectionAnnotations(conversationId: a.id)
        #expect(aAnnotations.map(\.text) == ["A1", "A2"])
    }
}
