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

    @Test("Persisted tool traces round-trip through the response projection")
    func toolTracesRoundTripThroughResponse() async throws {
        let fixture = try await makeFixture()
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)

        await inspector.didComposeTurn(fixture)

        // Enrich the row with a response that carries tool traces, the way
        // `ChatViewModel.persistResponse` does after a turn completes.
        let traces = [
            ToolTraceDTO(
                id: "call_1",
                name: "calculator",
                status: .success,
                arguments: "{\"expression\":\"2 + 2\"}",
                output: "4",
                error: nil,
                elapsedMillis: 12
            ),
            ToolTraceDTO(id: "call_2", name: "broken_tool", status: .failure, error: "boom"),
        ]
        try await inspector.updateResponse(
            conversationId: fixture.timelineId,
            turnIndex: 0,
            response: ResponseDTO(
                reconstructedText: "done",
                thinking: "",
                tools: traces
            )
        )

        let saved = try await inspector.inspection(conversationId: fixture.timelineId, turnIndex: 0)
        let response = try #require(saved?.response)
        #expect(response.tools.count == 2)
        #expect(response.tools.first?.id == "call_1")
        #expect(response.tools.first?.name == "calculator")
        #expect(response.tools.first?.status == .success)
        #expect(response.tools.first?.arguments == "{\"expression\":\"2 + 2\"}")
        #expect(response.tools.first?.output == "4")
        #expect(response.tools.first?.elapsedMillis == 12)
        #expect(response.tools.last?.status == .failure)
        #expect(response.tools.last?.error == "boom")

        // The presentation read seam surfaces the same traces.
        let presentation = try #require(try await inspector.presentation(conversationId: fixture.timelineId, turnIndex: 0))
        #expect(presentation.response?.tools.map(\.status) == [.success, .failure])
    }

    @Test("A ChatTurnState projects its ordered tool traces to DTOs")
    func chatTurnStateProjectsTraces() {
        var state = ChatTurnState(turnIndex: 0)
        let clock = ContinuousClock()
        let start = clock.now
        state.applyToolCallDelta(ToolCallDelta(index: 0, id: "c1", name: "calculator", arguments: "{\"expression\":\"2 + 2\"}"))
        state.applyToolStatus(
            id: "c1",
            status: .attempting(name: "calculator", reference: .known("calculator")),
            now: start
        )
        state.applyToolStatus(
            id: "c1",
            status: .success(.success("4")),
            now: start.advanced(by: .milliseconds(7))
        )

        let dtos = state.toolTraceDTOs
        #expect(dtos.count == 1)
        #expect(dtos.first?.id == "c1")
        #expect(dtos.first?.name == "calculator")
        #expect(dtos.first?.status == .success)
        #expect(dtos.first?.arguments == "{\"expression\":\"2 + 2\"}")
        #expect(dtos.first?.output == "4")
        #expect((dtos.first?.elapsedMillis ?? 0) > 0)
    }
}
