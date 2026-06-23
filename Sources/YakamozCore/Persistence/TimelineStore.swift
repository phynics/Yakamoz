import Foundation
import PKShared
import PositronicKit
import SwiftData

extension TimelineModel {
    convenience init(_ timeline: Timeline) throws {
        let idsData: Data
        do {
            idsData = try JSONEncoder().encode(timeline.attachedWorkspaceIds)
        } catch {
            throw PersistenceError.encoding("Timeline.attachedWorkspaceIds: \(error)")
        }
        self.init(
            id: timeline.id,
            title: timeline.title,
            createdAt: timeline.createdAt,
            updatedAt: timeline.updatedAt,
            isArchived: timeline.isArchived,
            workingDirectory: timeline.workingDirectory,
            attachedWorkspaceIdsData: idsData,
            attachedAgentInstanceId: timeline.attachedAgentInstanceId,
            isPrivate: timeline.isPrivate
        )
    }

    func toTimeline() throws -> Timeline {
        let ids: [UUID]
        do {
            ids = try JSONDecoder().decode([UUID].self, from: attachedWorkspaceIdsData)
        } catch {
            throw PersistenceError.decoding("Timeline.attachedWorkspaceIds: \(error)")
        }
        return Timeline(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived,
            workingDirectory: workingDirectory,
            attachedWorkspaceIds: ids,
            attachedAgentInstanceId: attachedAgentInstanceId,
            isPrivate: isPrivate
        )
    }

    /// Applies the mutable fields of `timeline` onto this existing model, in place
    /// (used by `saveTimeline` upsert semantics so identity/relationships aren't lost).
    func update(from timeline: Timeline) throws {
        let idsData: Data
        do {
            idsData = try JSONEncoder().encode(timeline.attachedWorkspaceIds)
        } catch {
            throw PersistenceError.encoding("Timeline.attachedWorkspaceIds: \(error)")
        }
        title = timeline.title
        createdAt = timeline.createdAt
        updatedAt = timeline.updatedAt
        isArchived = timeline.isArchived
        workingDirectory = timeline.workingDirectory
        attachedWorkspaceIdsData = idsData
        attachedAgentInstanceId = timeline.attachedAgentInstanceId
        isPrivate = timeline.isPrivate
    }
}

/// `TimelinePersistenceProtocol` adapter persisting `Timeline` values as
/// `TimelineModel` rows. See `SwiftDataMessageStore` for the actor-confinement
/// rationale shared by all adapters in this directory.
@ModelActor
public actor SwiftDataTimelineStore: TimelinePersistenceProtocol {
    public func saveTimeline(_ timeline: Timeline) async throws {
        let id = timeline.id
        let descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: timeline)
        } else {
            try modelContext.insert(TimelineModel(timeline))
        }
        try modelContext.save()
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        var descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        return try model.toTimeline()
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        let descriptor: FetchDescriptor<TimelineModel>
        if includeArchived {
            descriptor = FetchDescriptor<TimelineModel>(sortBy: [SortDescriptor(\.createdAt)])
        } else {
            descriptor = FetchDescriptor<TimelineModel>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        }
        return try modelContext.fetch(descriptor).map { try $0.toTimeline() }
    }

    public func deleteTimeline(id: UUID) async throws {
        try modelContext.delete(model: TimelineModel.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.createdAt < cutoff })
        let candidates = try modelContext.fetch(descriptor).filter { !excludedTimelineIds.contains($0.id) }
        if !dryRun {
            for model in candidates {
                modelContext.delete(model)
            }
            try modelContext.save()
        }
        return candidates.count
    }
}
