import Foundation

/// Pure, testable projection of the journal tab's volatile-section filtering, extracted
/// from `JournalInspectorView` so the YAK-16 regression surface ("everything marked
/// volatile") is unit-testable without a SwiftUI render.
///
/// The journal tab contrasts the prompt's **stable prefix** (sections carried over
/// unchanged from the previous turn) against its **volatile** portion — sections whose
/// semi-stable IDs changed or were added this turn. This type owns that intersection:
/// it flattens the persisted section tree back to render order, then keeps only the
/// sections whose IDs appear in `changedSemiStableIDs` ∪ `addedSemiStableIDs`.
public struct JournalInspectorProjection: Sendable, Equatable {
    /// Depth-first flatten of `sectionTree`, mirroring the render order the prompt
    /// assembler produced. Exposed so the flattening itself is testable in isolation.
    public let flatSections: [InspectionSectionDTO]

    /// Sections whose semi-stable IDs appear in `changedSemiStableIDs` ∪
    /// `addedSemiStableIDs` — i.e. the portion of the prompt that re-rendered this turn.
    /// Order follows `flatSections`. A section is included at most once even if its ID
    /// is listed under both `changed` and `added` (the match is a set intersection
    /// against the flattened list, not a concatenation of the ID arrays).
    public let volatileSections: [InspectionSectionDTO]

    public init(
        sectionTree: [InspectionSectionNode],
        changedSemiStableIDs: [String],
        addedSemiStableIDs: [String]
    ) {
        let flat = Self.flatten(sectionTree)
        let volatileIDs = Set(changedSemiStableIDs)
            .union(addedSemiStableIDs)
        self.flatSections = flat
        self.volatileSections = flat.filter { volatileIDs.contains($0.id) }
    }

    /// Convenience: derives the projection from a fully-built presentation, reading the
    /// section tree and journal overlay the inspector tab already renders from.
    public init(inspection: InspectionPresentation) {
        self.init(
            sectionTree: inspection.sectionTree,
            changedSemiStableIDs: inspection.journal.changedSemiStableIDs,
            addedSemiStableIDs: inspection.journal.addedSemiStableIDs
        )
    }

    /// Depth-first flattening of a section tree back to the original render order.
    public static func flatten(_ tree: [InspectionSectionNode]) -> [InspectionSectionDTO] {
        var out: [InspectionSectionDTO] = []
        func walk(_ nodes: [InspectionSectionNode]) {
            for node in nodes {
                out.append(node.section)
                walk(node.children)
            }
        }
        walk(tree)
        return out
    }
}

/// Pure arithmetic for the journal tab's prev/next turn navigation, extracted so the
/// "turn 0 previous disabled / last turn next disabled" edges are unit-testable without
/// driving the SwiftUI buttons.
///
/// The actual "is this turn selectable?" predicate stays **injected** by the host — it
/// derives from the live transcript (see `ChatViewModel.canSelectInspectionTurn`), which
/// the inspector view does not own. This type therefore owns only the candidate index
/// derivation (`current ± 1`) and the disable wiring that turns the host's predicate
/// into the two button states, so that derivation can be pinned independently of how the
/// transcript decides selectability.
public struct TurnNavigationBounds: Sendable, Equatable {
    public let currentTurnIndex: Int
    public let previousTurnIndex: Int
    public let nextTurnIndex: Int

    public init(currentTurnIndex: Int) {
        self.currentTurnIndex = currentTurnIndex
        self.previousTurnIndex = currentTurnIndex - 1
        self.nextTurnIndex = currentTurnIndex + 1
    }

    /// Whether the previous-turn button should be enabled, given the host's selection
    /// predicate (e.g. `ChatViewModel.canSelectInspectionTurn`).
    public func canSelectPrevious(_ canSelectTurn: (Int) -> Bool) -> Bool {
        canSelectTurn(previousTurnIndex)
    }

    /// Whether the next-turn button should be enabled, given the host's selection predicate.
    public func canSelectNext(_ canSelectTurn: (Int) -> Bool) -> Bool {
        canSelectTurn(nextTurnIndex)
    }
}
