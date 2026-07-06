import Foundation
import SwiftData
import Testing
@testable import YakamozCore

@Suite("TimelineAnnotationModel")
@MainActor
struct TimelineAnnotationTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(YakamozSchema.models), configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test("persists and fetches in turn order, regardless of insertion order")
    func persistsAndFetchesInOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conversationId = UUID()

        let first = TimelineAnnotationModel(conversationId: conversationId, turnIndex: 2, kind: .sectionTitle, text: "Exploring the bug")
        let second = TimelineAnnotationModel(conversationId: conversationId, turnIndex: 7, kind: .sectionTitle, text: "Implementing the fix")
        // Insert out of turn order to prove the fetch sorts rather than relying on
        // insertion order.
        context.insert(second)
        context.insert(first)
        try context.save()

        var descriptor = FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == conversationId }
        )
        descriptor.sortBy = [SortDescriptor(\.turnIndex)]
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.text) == ["Exploring the bug", "Implementing the fix"])
        #expect(fetched.map(\.turnIndex) == [2, 7])
    }

    @Test("kind round-trips through kindRaw")
    func kindRoundTripsThroughKindRaw() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let annotation = TimelineAnnotationModel(
            conversationId: UUID(),
            turnIndex: 0,
            kind: .sectionTitle,
            text: "Phase"
        )
        context.insert(annotation)
        try context.save()

        #expect(annotation.kindRaw == TimelineAnnotationKind.sectionTitle.rawValue)
        #expect(annotation.kind == .sectionTitle)
    }

    @Test("an unknown persisted kindRaw degrades to .sectionTitle")
    func unknownKindRawDegradesToSectionTitle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let annotation = TimelineAnnotationModel(
            conversationId: UUID(),
            turnIndex: 0,
            kind: .sectionTitle,
            text: "Phase"
        )
        context.insert(annotation)
        // Simulate a future-kind value persisted by a newer app version that this
        // older version does not know about. The getter must not crash; it falls back
        // to `.sectionTitle` so the navigation bar still renders something.
        annotation.kindRaw = "future_topic_shift"
        try context.save()
        #expect(annotation.kind == .sectionTitle)
    }

    @Test("annotations are scoped by conversationId")
    func scopedByConversationId() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        context.insert(TimelineAnnotationModel(conversationId: a, turnIndex: 0, kind: .sectionTitle, text: "A1"))
        context.insert(TimelineAnnotationModel(conversationId: b, turnIndex: 0, kind: .sectionTitle, text: "B1"))
        context.insert(TimelineAnnotationModel(conversationId: a, turnIndex: 1, kind: .sectionTitle, text: "A2"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TimelineAnnotationModel>(
            predicate: #Predicate { $0.conversationId == a },
            sortBy: [SortDescriptor(\.turnIndex)]
        ))
        #expect(fetched.map(\.text) == ["A1", "A2"])
    }
}
