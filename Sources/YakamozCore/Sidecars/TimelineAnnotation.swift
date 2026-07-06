import Foundation
import SwiftData

/// The kind of navigation marker a `TimelineAnnotationModel` row represents. SID-2 ships
/// only `sectionTitle`; the enum leaves room for future annotation kinds (e.g. topic
/// shifts, decision points) without a schema migration, since the persisted column is
/// the raw `String`.
///
/// `conversationTitle` is deliberately omitted: the conversation title is a single
/// mutable field on `ConversationModel` (SID-1, Task 6), not a turn-anchored annotation
/// list — it has no navigation use case distinct from the sidebar title itself.
public enum TimelineAnnotationKind: String, Codable, Sendable {
    case sectionTitle
}

/// A turn-anchored navigation marker (SID-2): "the conversation shifted to a new phase
/// here." One row per accepted (non-null) section-title directive result — declines
/// produce no row, matching how title declines don't touch `ConversationModel`.
///
/// Persisted via SwiftData; registered in `YakamozSchema.models` so the production
/// `ModelContainer` carries it. The `kind` is stored as a raw `String` (`kindRaw`) so
/// future enum additions degrade gracefully under automatic lightweight migration (an
/// unknown persisted value falls back to `.sectionTitle`).
@Model
public final class TimelineAnnotationModel {
    @Attribute(.unique) public var id: UUID
    public var conversationId: UUID
    public var turnIndex: Int
    public var kindRaw: String
    public var text: String
    public var createdAt: Date

    public var kind: TimelineAnnotationKind {
        get { TimelineAnnotationKind(rawValue: kindRaw) ?? .sectionTitle }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        turnIndex: Int,
        kind: TimelineAnnotationKind,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.conversationId = conversationId
        self.turnIndex = turnIndex
        kindRaw = kind.rawValue
        self.text = text
        self.createdAt = createdAt
    }
}

/// App-target-safe view of a `TimelineAnnotationModel` row (SID-2): the navigation bar
/// chip the user taps to jump to a turn. The underlying `@Model` is not `Sendable` and
/// lives in SwiftData, so YakamozCore projects it into this value type for SwiftUI
/// consumption — mirroring how `ResponseDTO`/`SidecarResultView` keep the app target
/// insulated from `PKShared` types.
public struct SectionAnnotationView: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let turnIndex: Int
    public let text: String

    public init(id: UUID, turnIndex: Int, text: String) {
        self.id = id
        self.turnIndex = turnIndex
        self.text = text
    }

    public init(_ annotation: TimelineAnnotationModel) {
        self.init(id: annotation.id, turnIndex: annotation.turnIndex, text: annotation.text)
    }
}

public extension Array where Element == TimelineAnnotationModel {
    /// Projects persisted annotation rows into app-target-safe `SectionAnnotationView`s
    /// for the navigation bar, preserving turn order.
    var sectionAnnotationViews: [SectionAnnotationView] {
        map(SectionAnnotationView.init)
    }
}
