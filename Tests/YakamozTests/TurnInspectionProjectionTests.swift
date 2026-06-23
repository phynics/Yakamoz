import Foundation
import PKPrompt
import PKShared
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("TurnInspectionProjection")
struct TurnInspectionProjectionTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            ConversationModel.self,
            MessageModel.self,
            TurnInspectionModel.self,
            PersonaModel.self,
            WorkspaceModel.self,
        ])
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeFixture() async throws -> TurnInspection {
        let prompt = AnyPrompt.build {
            SystemPrompt("You are helpful")
            TextPrompt(
                "Profile: likes concise answers",
                id: "profile",
                priority: PromptPriority.high.rawValue,
                compression: .summarize,
                cachePolicy: .semiStable
            )
            UserPrompt("What's the weather today?")
        }

        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()

        let sentMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: "You are helpful"),
            LLMMessage(role: .user, content: "What's the weather today?"),
        ]

        let journal = TurnJournalSnapshot(
            overlay: PromptJournalDiff(
                changedSemiStableIDs: ["profile"],
                addedSemiStableIDs: [],
                removedSemiStableIDs: []
            ),
            stablePrefixCount: 1,
            didCompact: false
        )

        return TurnInspection(
            timelineId: UUID(),
            agentInstanceId: nil,
            turnIndex: 0,
            model: "gpt-test",
            rendered: rendered,
            sentMessages: sentMessages,
            journal: journal,
            estimatedTokens: rendered.estimatedTokens
        )
    }

    @Test("Projects and persists a TurnInspection, round-tripping every trait")
    func projectsAndPersists() async throws {
        let fixture = try await makeFixture()
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)

        await inspector.didComposeTurn(fixture)

        let saved = try await inspector.inspection(conversationId: fixture.timelineId, turnIndex: 0)
        let model = try #require(saved)

        #expect(model.conversationId == fixture.timelineId)
        #expect(model.turnIndex == 0)
        #expect(model.model == "gpt-test")
        #expect(model.estimatedTokens == fixture.estimatedTokens)

        let sections = model.sections
        #expect(sections.first?.content == "You are helpful")
        #expect(sections.map(\.id) == fixture.rendered.sections.map(\.id))
        #expect(sections.first(where: { $0.id == "profile" })?.cachePolicy == "semiStable")
        #expect(sections.first(where: { $0.id == "profile" })?.compression == "summarize")
        #expect(sections.first(where: { $0.id == "profile" })?.content == "Profile: likes concise answers")

        let messages = model.sentMessages
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.map(\.content) == fixture.sentMessages.map(\.content))

        let journal = model.journal
        #expect(journal.changedSemiStableIDs == ["profile"])
        #expect(journal.addedSemiStableIDs == [])
        #expect(journal.removedSemiStableIDs == [])
        #expect(journal.stablePrefixCount == 1)
        #expect(journal.didCompact == false)

        #expect(model.response == nil)
    }

    @Test("Missing inspections return nil")
    func missingInspectionReturnsNil() async throws {
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)

        let saved = try await inspector.inspection(conversationId: UUID(), turnIndex: 99)
        #expect(saved == nil)
    }
}
