import Foundation
import Testing
@testable import YakamozCore

@Suite("JournalInspectorProjection")
struct JournalInspectorProjectionTests {
    // MARK: - Fixtures

    /// Builds a section DTO with only the fields the projection reads (`id`, `path`,
    /// `role`); the rest are filler, mirroring the helper style in
    /// `InspectionViewModelTests`.
    private func section(
        id: String,
        parentID: String? = nil,
        role: String = "system"
    ) -> InspectionSectionDTO {
        InspectionSectionDTO(
            id: id,
            parentID: parentID,
            path: [id],
            role: role,
            priority: 0,
            compression: "none",
            cachePolicy: "stable",
            estimatedTokens: 1,
            compressionOutcome: nil,
            content: id
        )
    }

    private func node(id: String, children: [InspectionSectionNode] = [], role: String = "system") -> InspectionSectionNode {
        InspectionSectionNode(section: section(id: id, role: role), children: children)
    }

    // MARK: - Tree flattening

    @Test("Flattens a nested section tree depth-first, preserving render order")
    func flattensDepthFirst() {
        let tree = [
            node(id: "root-a", children: [
                node(id: "child-a1", children: [node(id: "grandchild")]),
                node(id: "child-a2"),
            ]),
            node(id: "root-b"),
        ]

        let flat = JournalInspectorProjection.flatten(tree)

        #expect(flat.map(\.id) == ["root-a", "child-a1", "grandchild", "child-a2", "root-b"])
    }

    @Test("An empty tree flattens to an empty list")
    func flattensEmpty() {
        #expect(JournalInspectorProjection.flatten([]).isEmpty)
    }

    // MARK: - Volatile-section intersection (YAK-16 regression surface)

    @Test("Matches only sections whose IDs are in changed ∪ added")
    func matchesChangedAndAdded() {
        let tree = [
            node(id: "system"),
            node(id: "profile"),
            node(id: "tools"),
            node(id: "user"),
        ]

        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: ["profile"],
            addedSemiStableIDs: ["tools"]
        )

        #expect(projection.volatileSections.map(\.id) == ["profile", "tools"])
        #expect(projection.flatSections.map(\.id) == ["system", "profile", "tools", "user"])
    }

    @Test("Empty changed+added yields NO volatile sections (not 'everything volatile')")
    func emptyDiffYieldsNone() {
        // The exact YAK-16 regression shape: an empty diff must NOT fall back to marking
        // every section volatile. An empty intersection is empty.
        let tree = [node(id: "system"), node(id: "profile"), node(id: "user")]

        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: [],
            addedSemiStableIDs: []
        )

        #expect(projection.volatileSections.isEmpty)
    }

    @Test("A changed ID not present in the tree is ignored (intersection, not union)")
    func changedIDOutsideTreeIgnored() {
        let tree = [node(id: "system"), node(id: "profile")]

        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: ["ghost"],
            addedSemiStableIDs: []
        )

        #expect(projection.volatileSections.isEmpty)
    }

    @Test("An ID listed under both changed and added appears once")
    func dedupesChangedAndAdded() {
        let tree = [node(id: "profile")]

        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: ["profile"],
            addedSemiStableIDs: ["profile"]
        )

        #expect(projection.volatileSections.count == 1)
        #expect(projection.volatileSections.first?.id == "profile")
    }

    @Test("Volatile output preserves tree order, not ID-array order")
    func preservesTreeOrder() {
        let tree = [node(id: "a"), node(id: "b"), node(id: "c")]

        // IDs declared out of tree order; output must still follow flatten order.
        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: ["b", "a"],
            addedSemiStableIDs: []
        )

        #expect(projection.volatileSections.map(\.id) == ["a", "b"])
    }

    @Test("Volatile matches recurse into nested children via the flattened tree")
    func matchesNestedChildren() {
        let tree = [
            node(id: "root", children: [
                node(id: "child", children: [node(id: "grandchild")]),
            ]),
        ]

        // Only the grandchild's semi-stable ID changed this turn.
        let projection = JournalInspectorProjection(
            sectionTree: tree,
            changedSemiStableIDs: ["grandchild"],
            addedSemiStableIDs: []
        )

        #expect(projection.volatileSections.map(\.id) == ["grandchild"])
        #expect(projection.flatSections.map(\.id) == ["root", "child", "grandchild"])
    }

    @Test("Derives from a full InspectionPresentation")
    func derivesFromPresentation() {
        let tree = [node(id: "system"), node(id: "profile")]
        let presentation = InspectionPresentation(
            conversationId: UUID(),
            turnIndex: 1,
            model: "m",
            createdAt: Date(),
            totalTokens: 0,
            sectionTree: tree,
            compression: CompressionSummary(sections: []),
            sentMessages: [],
            sentMessagesJSON: "[]",
            journal: JournalDTO(
                changedSemiStableIDs: ["profile"],
                addedSemiStableIDs: [],
                removedSemiStableIDs: [],
                stablePrefixCount: 1,
                didCompact: false
            ),
            response: nil
        )

        let projection = JournalInspectorProjection(inspection: presentation)

        #expect(projection.volatileSections.map(\.id) == ["profile"])
    }
}

@Suite("TurnNavigationBounds")
struct TurnNavigationBoundsTests {
    @Test("Previous/next indices are current ± 1")
    func derivesNeighbours() {
        let bounds = TurnNavigationBounds(currentTurnIndex: 3)
        #expect(bounds.currentTurnIndex == 3)
        #expect(bounds.previousTurnIndex == 2)
        #expect(bounds.nextTurnIndex == 4)
    }

    @Test("Turn 0 previous resolves to -1 (the host predicate disables it)")
    func turnZeroPrevious() {
        let bounds = TurnNavigationBounds(currentTurnIndex: 0)
        #expect(bounds.previousTurnIndex == -1)
        // No turn index -1 exists in any transcript, so the host predicate rejects it.
        let canSelect: (Int) -> Bool = { $0 >= 0 }
        #expect(!bounds.canSelectPrevious(canSelect))
    }

    @Test("canSelectPrevious/canSelectNext delegate to the injected predicate")
    func delegatesToPredicate() {
        let bounds = TurnNavigationBounds(currentTurnIndex: 2)
        #expect(bounds.previousTurnIndex == 1)
        #expect(bounds.nextTurnIndex == 3)

        // Only turn 2 itself is selectable: both neighbours disabled.
        let onlyCurrent: (Int) -> Bool = { $0 == 2 }
        #expect(!bounds.canSelectPrevious(onlyCurrent))
        #expect(!bounds.canSelectNext(onlyCurrent))

        // Previous selectable, next not.
        let prevOnly: (Int) -> Bool = { $0 == 1 }
        #expect(bounds.canSelectPrevious(prevOnly))
        #expect(!bounds.canSelectNext(prevOnly))

        // Next selectable, previous not.
        let nextOnly: (Int) -> Bool = { $0 == 3 }
        #expect(!bounds.canSelectPrevious(nextOnly))
        #expect(bounds.canSelectNext(nextOnly))
    }

    @Test("Last turn next resolves to one past the final index and is rejected by the host")
    func lastTurnNext() {
        // Four turns: 0..<4. Turn 3 is the last; its next is 4, which the host predicate
        // (the transcript contains no inspection row at 4) rejects.
        let lastTurn = 3
        let turnCount = 4
        let bounds = TurnNavigationBounds(currentTurnIndex: lastTurn)
        #expect(bounds.nextTurnIndex == 4)
        let canSelect: (Int) -> Bool = { $0 >= 0 && $0 < turnCount }
        #expect(!bounds.canSelectNext(canSelect))
        #expect(bounds.canSelectPrevious(canSelect)) // turn 2 exists
    }
}
