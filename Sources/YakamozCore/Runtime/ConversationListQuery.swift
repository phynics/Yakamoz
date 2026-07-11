import Foundation
import SwiftData

/// The persisted query used by ordinary timeline lists. Home timelines are only surfaced
/// through their owning agent's Chat view and must never be loaded into this collection.
public enum ConversationListQuery {
    public static var standardPredicate: Predicate<ConversationModel> {
        #Predicate { !$0.isHomeTimeline }
    }

    public static var descriptor: FetchDescriptor<ConversationModel> {
        FetchDescriptor(
            predicate: standardPredicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }
}
