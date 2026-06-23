import Foundation
import PKPrompt
import PKShared
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("InspectionViewModel")
struct InspectionViewModelTests {
    // MARK: - Fixtures

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

    /// Builds a `TurnInspection` for `conversationId`/`turnIndex` whose `profile` section
    /// uses summarization (so compression totals are exercised) and whose journal marks
    /// `profile` as changed.
    private func makeFixture(conversationId: UUID, turnIndex: Int) async throws -> TurnInspection {
        let prompt = AnyPrompt.build {
            SystemPrompt("You are helpful")
            TextPrompt(
                "Profile: likes concise answers",
                id: "profile",
                priority: PromptPriority.high.rawValue,
                compression: .summarize,
                cachePolicy: .semiStable
            )
            UserPrompt("Turn \(turnIndex) question?")
        }

        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()

        let sentMessages: [LLMMessage] = [
            LLMMessage(role: .system, content: "You are helpful"),
            LLMMessage(role: .user, content: "Turn \(turnIndex) question?"),
        ]

        let journal = TurnJournalSnapshot(
            overlay: PromptJournalDiff(
                changedSemiStableIDs: ["profile"],
                addedSemiStableIDs: [],
                removedSemiStableIDs: []
            ),
            stablePrefixCount: 1,
            didCompact: turnIndex == 1
        )

        return TurnInspection(
            timelineId: conversationId,
            agentInstanceId: nil,
            turnIndex: turnIndex,
            model: "gpt-test",
            rendered: rendered,
            sentMessages: sentMessages,
            journal: journal,
            estimatedTokens: rendered.estimatedTokens
        )
    }

    // MARK: - Selection / projection through SwiftDataTurnInspector

    @Test("Selecting a turn fetches only the matching key and projects every DTO")
    func selectsMatchingTurn() async throws {
        let conversationId = UUID()
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)

        let turn0 = try await makeFixture(conversationId: conversationId, turnIndex: 0)
        let turn1 = try await makeFixture(conversationId: conversationId, turnIndex: 1)
        await inspector.didComposeTurn(turn0)
        await inspector.didComposeTurn(turn1)

        let viewModel = await InspectionViewModel(repository: inspector)
        await viewModel.select(conversationId: conversationId, turnIndex: 1)

        let presentation = try #require(await viewModel.inspection)
        #expect(presentation.turnIndex == 1)
        #expect(presentation.conversationId == conversationId)
        #expect(presentation.model == "gpt-test")
        #expect(presentation.totalTokens == turn1.estimatedTokens)
        #expect(presentation.journal.didCompact == true)
        #expect(presentation.journal.changedSemiStableIDs == ["profile"])
        #expect(presentation.sentMessages.map(\.role) == ["system", "user"])
        #expect(presentation.sentMessages.last?.content == "Turn 1 question?")
        #expect(await viewModel.loadError == nil)

        // Turn 0 must be reachable and distinct (only the matching key is fetched).
        await viewModel.select(conversationId: conversationId, turnIndex: 0)
        let zero = try #require(await viewModel.inspection)
        #expect(zero.turnIndex == 0)
        #expect(zero.journal.didCompact == false)
        #expect(zero.sentMessages.last?.content == "Turn 0 question?")
    }

    @Test("A turn with no inspection row yields an explicit empty (nil) state")
    func missingTurnIsEmpty() async throws {
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)
        let viewModel = await InspectionViewModel(repository: inspector)

        await viewModel.select(conversationId: UUID(), turnIndex: 7)
        #expect(await viewModel.inspection == nil)
        #expect(await viewModel.loadError == nil)
    }

    @Test("Nil turnIndex clears any loaded inspection")
    func nilTurnIndexClears() async throws {
        let conversationId = UUID()
        let container = try makeContainer()
        let inspector = SwiftDataTurnInspector(modelContainer: container)
        try await inspector.didComposeTurn(await makeFixture(conversationId: conversationId, turnIndex: 0))

        let viewModel = await InspectionViewModel(repository: inspector)
        await viewModel.select(conversationId: conversationId, turnIndex: 0)
        #expect(await viewModel.inspection != nil)

        await viewModel.select(conversationId: conversationId, turnIndex: nil)
        #expect(await viewModel.inspection == nil)
    }

    // MARK: - Presentation derivation

    @Test("Builds a parent/child section tree by parentID, preserving order")
    func buildsSectionTree() {
        let sections = [
            section(id: "root-a", parentID: nil, content: "A"),
            section(id: "child-a1", parentID: "root-a", content: "A1"),
            section(id: "child-a2", parentID: "root-a", content: "A2"),
            section(id: "root-b", parentID: nil, content: "B"),
            section(id: "grandchild", parentID: "child-a1", content: "A1a"),
            // parentID points outside the set -> treated as a root.
            section(id: "orphan", parentID: "ghost", content: "O"),
        ]

        let tree = InspectionPresentation.buildTree(sections)

        #expect(tree.map(\.id) == ["root-a", "root-b", "orphan"])
        let rootA = tree[0]
        #expect(rootA.children.map(\.id) == ["child-a1", "child-a2"])
        #expect(rootA.children[0].children.map(\.id) == ["grandchild"])
        #expect(tree[2].children.isEmpty)
    }

    @Test("Formats sent messages as pretty JSON with sorted keys")
    func formatsSortedKeyJSON() throws {
        let messages = [
            InspectionMessageDTO(role: "user", content: "hi", toolCallID: "call-1"),
        ]
        let presentation = InspectionPresentation(
            conversationId: UUID(),
            turnIndex: 0,
            model: "m",
            createdAt: Date(),
            totalTokens: 0,
            sectionTree: [],
            compression: CompressionSummary(sections: []),
            sentMessages: messages,
            sentMessagesJSON: InspectionPresentation.prettyJSON(messages),
            journal: JournalDTO(
                changedSemiStableIDs: [], addedSemiStableIDs: [], removedSemiStableIDs: [],
                stablePrefixCount: 0, didCompact: false
            ),
            response: nil
        )

        let json = presentation.sentMessagesJSON
        // Sorted keys: content < role < toolCallID alphabetically.
        let contentIdx = try #require(json.range(of: "\"content\""))
        let roleIdx = try #require(json.range(of: "\"role\""))
        let toolIdx = try #require(json.range(of: "\"toolCallID\""))
        #expect(contentIdx.lowerBound < roleIdx.lowerBound)
        #expect(roleIdx.lowerBound < toolIdx.lowerBound)
        // Pretty-printed -> contains newlines and indentation.
        #expect(json.contains("\n"))
    }

    @Test("Computes compression totals from section outcomes")
    func computesCompressionTotals() {
        let sections = [
            section(id: "a", parentID: nil, content: "a", compression: "none", outcome: nil),
            section(id: "b", parentID: nil, content: "b", compression: "summarize", outcome: "summarized to 10 tokens"),
            section(id: "c", parentID: nil, content: "c", compression: "truncate", outcome: nil),
        ]
        let summary = CompressionSummary(sections: sections)
        #expect(summary.total == 3)
        #expect(summary.compressed == 2) // b + c are non-"none"
        #expect(summary.withOutcome == 1) // only b recorded an outcome
        #expect(summary.label == "2 / 3 sections compressed")
    }

    // MARK: - Fake repository injection

    @Test("Injected fake repository surfaces its presentation without SwiftData")
    func injectedFake() async {
        let expected = InspectionPresentation(
            conversationId: UUID(),
            turnIndex: 3,
            model: "fake",
            createdAt: Date(),
            totalTokens: 42,
            sectionTree: [],
            compression: CompressionSummary(sections: []),
            sentMessages: [],
            sentMessagesJSON: "[]",
            journal: JournalDTO(
                changedSemiStableIDs: [], addedSemiStableIDs: [], removedSemiStableIDs: [],
                stablePrefixCount: 0, didCompact: false
            ),
            response: nil
        )
        let viewModel = await InspectionViewModel(repository: FakeReader(result: .success(expected)))
        await viewModel.select(conversationId: expected.conversationId, turnIndex: 3)
        #expect(await viewModel.inspection == expected)
    }

    @Test("A repository error surfaces via loadError and clears the inspection")
    func repositoryError() async {
        let viewModel = await InspectionViewModel(repository: FakeReader(result: .failure(FakeError.boom)))
        await viewModel.select(conversationId: UUID(), turnIndex: 0)
        #expect(await viewModel.inspection == nil)
        #expect(await viewModel.loadError != nil)
    }

    // MARK: - Helpers

    private func section(
        id: String,
        parentID: String?,
        content: String,
        compression: String = "none",
        outcome: String? = nil
    ) -> InspectionSectionDTO {
        InspectionSectionDTO(
            id: id,
            parentID: parentID,
            path: [id],
            role: "system",
            priority: 0,
            compression: compression,
            cachePolicy: "stable",
            estimatedTokens: 1,
            compressionOutcome: outcome,
            content: content
        )
    }
}

private enum FakeError: Error { case boom }

private struct FakeReader: InspectionReading {
    let result: Result<InspectionPresentation?, Error>

    func presentation(conversationId _: UUID, turnIndex _: Int) async throws -> InspectionPresentation? {
        try result.get()
    }
}
