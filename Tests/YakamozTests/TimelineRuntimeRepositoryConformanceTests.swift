import Foundation
import PKTestSupport
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
        try await TimelineRuntimeRepositoryConformanceSuite.run(summaryStorage: .required) {
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
}
