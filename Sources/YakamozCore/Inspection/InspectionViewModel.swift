import Foundation

/// A node in the prompt section tree: an `InspectionSectionDTO` plus its children,
/// nested by `parentID`. Order is preserved from the persisted section array.
public struct InspectionSectionNode: Sendable, Equatable, Identifiable {
    public let section: InspectionSectionDTO
    public let children: [InspectionSectionNode]

    public var id: String {
        section.id
    }

    public init(section: InspectionSectionDTO, children: [InspectionSectionNode]) {
        self.section = section
        self.children = children
    }
}

/// Aggregate compression statistics derived from the section DTOs of a single turn.
///
/// `total` counts every section; `compressed` counts sections whose `compression`
/// trait is anything other than `"none"`; `withOutcome` counts sections that recorded
/// a non-nil `compressionOutcome` (i.e. compression actually ran and produced a result).
public struct CompressionSummary: Sendable, Equatable {
    public let total: Int
    public let compressed: Int
    public let withOutcome: Int

    public init(total: Int, compressed: Int, withOutcome: Int) {
        self.total = total
        self.compressed = compressed
        self.withOutcome = withOutcome
    }

    /// Builds the summary from a flat list of section DTOs.
    public init(sections: [InspectionSectionDTO]) {
        total = sections.count
        compressed = sections.filter { $0.compression != "none" }.count
        withOutcome = sections.filter { $0.compressionOutcome != nil }.count
    }

    /// A short human-readable phrase, e.g. "3 / 12 sections compressed".
    public var label: String {
        "\(compressed) / \(total) sections compressed"
    }
}

/// A fully-built, `Sendable` presentation of one persisted turn inspection, ready for
/// the SwiftUI inspector tabs. All derivation (tree building, JSON formatting,
/// compression totals) happens once here rather than recomputed in view bodies.
public struct InspectionPresentation: Sendable, Equatable {
    public let conversationId: UUID
    public let turnIndex: Int
    public let model: String
    public let createdAt: Date
    public let totalTokens: Int

    /// Root-level section nodes (those whose `parentID` is nil or points outside the
    /// set), each carrying nested children. Order preserved from the persisted array.
    public let sectionTree: [InspectionSectionNode]
    public let compression: CompressionSummary

    public let sentMessages: [InspectionMessageDTO]
    /// `sentMessages` re-encoded as pretty-printed JSON with sorted keys, for the
    /// "raw" segment of the Sent tab. Empty string only if encoding somehow fails.
    public let sentMessagesJSON: String

    public let journal: JournalDTO
    public let response: ResponseDTO?

    public init(
        conversationId: UUID,
        turnIndex: Int,
        model: String,
        createdAt: Date,
        totalTokens: Int,
        sectionTree: [InspectionSectionNode],
        compression: CompressionSummary,
        sentMessages: [InspectionMessageDTO],
        sentMessagesJSON: String,
        journal: JournalDTO,
        response: ResponseDTO?
    ) {
        self.conversationId = conversationId
        self.turnIndex = turnIndex
        self.model = model
        self.createdAt = createdAt
        self.totalTokens = totalTokens
        self.sectionTree = sectionTree
        self.compression = compression
        self.sentMessages = sentMessages
        self.sentMessagesJSON = sentMessagesJSON
        self.journal = journal
        self.response = response
    }

    /// Derives a presentation from the raw persisted inspection: builds the section
    /// tree by `parentID`, computes compression totals, and formats the sent-messages
    /// JSON with sorted keys.
    public init(_ persisted: PersistedTurnInspection) {
        conversationId = persisted.conversationId
        turnIndex = persisted.turnIndex
        model = persisted.model
        createdAt = persisted.createdAt
        totalTokens = persisted.estimatedTokens
        sectionTree = Self.buildTree(persisted.sections)
        compression = CompressionSummary(sections: persisted.sections)
        sentMessages = persisted.sentMessages
        sentMessagesJSON = Self.prettyJSON(persisted.sentMessages)
        journal = persisted.journal
        response = persisted.response
    }

    /// Builds a parent/child tree from a flat, order-preserving section list. A section
    /// is a child of another when its `parentID` matches that section's `id` and the
    /// parent exists in the list; otherwise it is treated as a root. Sibling order
    /// follows the original array order.
    static func buildTree(_ sections: [InspectionSectionDTO]) -> [InspectionSectionNode] {
        let ids = Set(sections.map(\.id))
        var childrenByParent: [String: [InspectionSectionDTO]] = [:]
        var roots: [InspectionSectionDTO] = []

        for section in sections {
            if let parentID = section.parentID, parentID != section.id, ids.contains(parentID) {
                childrenByParent[parentID, default: []].append(section)
            } else {
                roots.append(section)
            }
        }

        func node(for section: InspectionSectionDTO) -> InspectionSectionNode {
            let children = (childrenByParent[section.id] ?? []).map(node(for:))
            return InspectionSectionNode(section: section, children: children)
        }

        return roots.map(node(for:))
    }

    /// Pretty-prints a Codable value to a sorted-key JSON string. Returns "[]" / a
    /// best-effort fallback if encoding fails (it should not for these DTOs).
    static func prettyJSON(_ messages: [InspectionMessageDTO]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(messages),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }
}

/// Read seam for the inspector: fetches and projects a persisted turn inspection into
/// a `Sendable` `InspectionPresentation`. `SwiftDataTurnInspector` conforms (via an
/// extension); tests substitute a fake that returns hand-built presentations without
/// SwiftData.
public protocol InspectionReading: Sendable {
    func presentation(conversationId: UUID, turnIndex: Int) async throws -> InspectionPresentation?
}

extension SwiftDataTurnInspector: InspectionReading {
    public func presentation(conversationId: UUID, turnIndex: Int) async throws -> InspectionPresentation? {
        guard let persisted = try inspection(conversationId: conversationId, turnIndex: turnIndex) else {
            return nil
        }
        return InspectionPresentation(persisted)
    }
}

/// Main-actor, `@Observable` view model that drives the inspector drawer. Loads the
/// presentation for the currently-selected turn through an injected `InspectionReading`
/// and exposes it (or an explicit empty/`nil` state) to the SwiftUI tabs.
@MainActor
@Observable
public final class InspectionViewModel {
    public private(set) var inspection: InspectionPresentation?
    public private(set) var loadError: String?

    private let repository: any InspectionReading

    public init(repository: any InspectionReading) {
        self.repository = repository
    }

    /// Loads the inspection for `turnIndex` (clearing state when `turnIndex` is nil, the
    /// explicit "no turn selected" case). A fetch failure surfaces via `loadError` and
    /// leaves `inspection` nil so the UI shows an unavailable state rather than stale data.
    public func select(conversationId: UUID, turnIndex: Int?) async {
        guard let turnIndex else {
            inspection = nil
            loadError = nil
            return
        }
        do {
            loadError = nil
            inspection = try await repository.presentation(conversationId: conversationId, turnIndex: turnIndex)
        } catch {
            loadError = error.localizedDescription
            inspection = nil
        }
    }
}
