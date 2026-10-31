import Foundation
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// Issue #18: run the upstream conformance suite against the SwiftData adapter on a
/// fresh in-memory `ModelContainer` per scenario, so adapter gaps surface as test
/// failures instead of drifting silently.
@Suite("TimelineRuntimeRepository conformance")
struct TimelineRuntimeRepositoryConformanceTests {
    @Test("SwiftDataTimelineRuntimeRepository passes the upstream conformance suite")
    func passesConformanceSuite() async throws {
        try await TimelineRuntimeRepositoryConformanceSuite.run {
            let container = try ModelContainer(
                for: Schema(YakamozSchema.models),
                configurations: .init(isStoredInMemoryOnly: true)
            )
            return SwiftDataTimelineRuntimeRepository(modelContainer: container)
        }
    }

    @Test("A fresh repository rehydrates a durable Timeline before Turn admission")
    func rehydratesTimelineAfterRepositoryRecreation() async throws {
        let container = try ModelContainer(
            for: Schema(YakamozSchema.models),
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let timelineID = UUID()
        let now = Date()
        let firstRepository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        try await firstRepository.saveTimeline(
            YakamozThread(id: timelineID, title: "Reloaded", createdAt: now, updatedAt: now)
        )

        let reloadedRepository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let admission = try await reloadedRepository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "restart-test",
            inputMessage: nil,
            executionKind: .agentManaged,
            capturedAgentID: nil,
            turnID: UUID(),
            now: now
        )

        #expect(admission.disposition == .admitted)
    }

    // MARK: - Durable Turn membership

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(YakamozSchema.models),
            configurations: .init(isStoredInMemoryOnly: true)
        )
    }

    /// Reads committed rows through a context of its own, so a row the repository only
    /// staged in its context is not visible here.
    private func committedMemberships(in container: ModelContainer, turnID: UUID) throws -> [TurnMessageMembershipModel] {
        try ModelContext(container).fetch(FetchDescriptor<TurnMessageMembershipModel>(
            predicate: #Predicate { $0.turnId == turnID },
            sortBy: [SortDescriptor(\.ordinal)]
        ))
    }

    private func committedMessageIDs(in container: ModelContainer, timelineID: UUID) throws -> [UUID] {
        try ModelContext(container).fetch(FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineID }
        )).map(\.id)
    }

    @Test("recordTurnMessage commits the message and its membership row together")
    func recordTurnMessageCommitsMembership() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "input")
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: input.id,
            callerIntentFingerprint: "input",
            inputMessage: input
        )
        let turnID = admission.turn.identity.turnID
        let intermediate = TimelineMessage(timelineID: timelineID, role: .assistant, content: "tool call")

        try await repository.recordTurnMessage(intermediate, turnID: turnID)

        #expect(try committedMemberships(in: container, turnID: turnID).map(\.messageId) == [input.id, intermediate.id])
        #expect(try committedMemberships(in: container, turnID: turnID).map(\.ordinal) == [0, 1])
        #expect(Set(try committedMessageIDs(in: container, timelineID: timelineID)) == [input.id, intermediate.id])
    }

    @Test("A rejected recordTurnMessage writes neither the message nor a membership row")
    func rejectedRecordTurnMessageWritesNothing() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        let unknownTurnID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let message = TimelineMessage(timelineID: timelineID, role: .assistant, content: "orphan")

        await #expect(throws: TimelineRuntimeRepositoryError.turnNotFound(unknownTurnID)) {
            try await repository.recordTurnMessage(message, turnID: unknownTurnID)
        }

        #expect(try committedMemberships(in: container, turnID: unknownTurnID).isEmpty)
        #expect(try committedMessageIDs(in: container, timelineID: timelineID).isEmpty)
    }

    @Test("Every Turn-owned write records membership, in repository write order")
    func toolAndTerminalWritesRecordMembership() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "no-input"
        )
        let turnID = admission.turn.identity.turnID
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: turnID, timelineID: timelineID, toolCallID: "call-1", name: "lookup",
            arguments: "{}", modelRoundIndex: 0
        ))
        let tool = TimelineMessage(timelineID: timelineID, role: .tool, content: "result", toolCallID: "call-1")
        try await repository.recordToolResult(
            RuntimeToolResult(turnID: turnID, timelineID: timelineID, toolCallID: "call-1", output: "result"),
            message: tool
        )
        let final = TimelineMessage(timelineID: timelineID, role: .assistant, content: "final")
        _ = try await repository.completeTurn(turnID: turnID, finalMessage: final)
        _ = try await repository.completeTurn(turnID: turnID, finalMessage: final)

        #expect(try committedMemberships(in: container, turnID: turnID).map(\.messageId) == [tool.id, final.id])
    }

    @Test("A retried Turn adopts its predecessor's stored input as a member of both")
    func retryAdoptsInputMembership() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        let requestID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let input = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "input")
        let first = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "input",
            inputMessage: input
        )
        _ = try await repository.failTurn(turnID: first.turn.identity.turnID, message: "provider failed")
        let retryTurnID = UUID()

        _ = try await repository.admitRetry(
            timelineID: timelineID,
            previousTurnID: first.turn.identity.turnID,
            requestID: requestID,
            callerIntentFingerprint: "input",
            inputMessage: input,
            executionKind: .agentManaged,
            capturedAgentID: nil,
            turnID: retryTurnID,
            attempt: 2,
            now: Date()
        )

        #expect(try committedMemberships(in: container, turnID: first.turn.identity.turnID).map(\.messageId) == [input.id])
        #expect(try committedMemberships(in: container, turnID: retryTurnID).map(\.messageId) == [input.id])
        #expect(try committedMessageIDs(in: container, timelineID: timelineID) == [input.id])
    }

    @Test("Membership survives a repository restart; an unknown Turn stays nil")
    func membershipSurvivesRestart() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "input")
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: input.id,
            callerIntentFingerprint: "input",
            inputMessage: input
        )

        let reloaded = SwiftDataTimelineRuntimeRepository(modelContainer: container)

        let members = try await reloaded.fetchTurnMessages(turnID: admission.turn.identity.turnID)
        #expect(members?.map(\.id) == [input.id])
        #expect(try await reloaded.fetchTurnMessages(turnID: UUID()) == nil)
    }

    @Test("A known Turn with no messages has an empty membership list")
    func messageFreeTurnHasEmptyMembership() async throws {
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: try makeContainer())
        let timelineID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID))
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: UUID(),
            callerIntentFingerprint: "no-input"
        )

        let members = try await repository.fetchTurnMessages(turnID: admission.turn.identity.turnID)
        #expect(members?.isEmpty == true)
    }

    @Test("Deleting a Timeline removes its membership and lifetime rows")
    func deleteCascadesToMembershipAndLifetime() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let timelineID = UUID()
        try await repository.saveTimeline(YakamozThread(id: timelineID, isEphemeral: true))
        let input = TimelineMessage(timelineID: timelineID, role: .user, content: "input")
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: input.id,
            callerIntentFingerprint: "input",
            inputMessage: input
        )
        _ = try await repository.completeTurn(turnID: admission.turn.identity.turnID)

        try await repository.deleteEphemeralTimeline(id: timelineID)

        #expect(try committedMemberships(in: container, turnID: admission.turn.identity.turnID).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TimelineLifetimeModel>()).isEmpty)
    }

    // MARK: - Timeline lifetime

    @Test("Ephemeral and fork lineage fields round-trip, and an ordinary Timeline has no row")
    func timelineLifetimeRoundTrips() async throws {
        let container = try makeContainer()
        let repository = SwiftDataTimelineRuntimeRepository(modelContainer: container)
        let forkID = UUID()
        let origin = TimelineForkOrigin(timelineID: UUID(), throughMessageID: UUID(), at: Date(timeIntervalSince1970: 100))
        try await repository.saveTimeline(YakamozThread(id: forkID, isEphemeral: true, forkedFrom: origin))
        let ordinaryID = UUID()
        try await repository.saveTimeline(YakamozThread(id: ordinaryID))

        let fork = try await repository.fetchTimeline(id: forkID)
        #expect(fork?.isEphemeral == true)
        #expect(fork?.forkedFrom == origin)
        let ordinary = try await repository.fetchTimeline(id: ordinaryID)
        #expect(ordinary?.isEphemeral == false)
        #expect(ordinary?.forkedFrom == nil)
        let all = try await repository.fetchAllTimelines(includeArchived: true)
        #expect(all.first { $0.id == forkID }?.isEphemeral == true)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TimelineLifetimeModel>()).map(\.timelineId) == [forkID])

        try await repository.saveTimeline(YakamozThread(id: forkID))
        #expect(try ModelContext(container).fetch(FetchDescriptor<TimelineLifetimeModel>()).isEmpty)
    }
}
