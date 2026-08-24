import Foundation
import Logging
import PKContracts
import PositronicKit
import SwiftData

extension TimelineModel {
    convenience init(_ thread: YakamozThread) throws {
        self.init(
            id: thread.id,
            title: thread.title,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            isArchived: thread.isArchived,
            workingDirectory: thread.workingDirectory,
            attachedWorkspaceIdsData: try JSONEncoder().encode(thread.attachedWorkspaceIDs),
            attachedAgentInstanceId: thread.attachedAgentID,
            isPrivate: thread.isPrivate
        )
    }

    func toThread() throws -> YakamozThread {
        return YakamozThread(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived,
            workingDirectory: workingDirectory,
            attachedWorkspaceIDs: (try? JSONDecoder().decode([UUID].self, from: attachedWorkspaceIdsData)) ?? [],
            attachedAgentID: attachedAgentInstanceId,
            isPrivate: isPrivate
        )
    }

    /// Applies the mutable fields of `timeline` onto this existing model, in place
    /// (used by `saveTimeline` upsert semantics so identity/relationships aren't lost).
    func update(from thread: YakamozThread) throws {
        title = thread.title
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        isArchived = thread.isArchived
        workingDirectory = thread.workingDirectory
        attachedWorkspaceIdsData = try JSONEncoder().encode(thread.attachedWorkspaceIDs)
        attachedAgentInstanceId = thread.attachedAgentID
        isPrivate = thread.isPrivate
    }
}

/// `ThreadPersistenceProtocol` adapter persisting `Thread` values as
/// `TimelineModel` rows. See `SwiftDataMessageStore` for the actor-confinement
/// rationale shared by all adapters in this directory.
@ModelActor
public actor SwiftDataTimelineStore: ThreadPersistenceProtocol {
    public nonisolated let isDurable = true

    public func saveThread(_ thread: YakamozThread) async throws {
        let id = thread.id
        let descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: thread)
        } else {
            try modelContext.insert(TimelineModel(thread))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save Thread", metadata: [
                "store": "TimelineStore",
                "threadID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchThread(id: UUID) async throws -> YakamozThread? {
        var descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            guard let model = try modelContext.fetch(descriptor).first else { return nil }
            return try model.toThread()
        } catch {
            Log.runtime.warning("failed to fetch Thread", metadata: [
                "store": "TimelineStore",
                "threadID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [YakamozThread] {
        let descriptor: FetchDescriptor<TimelineModel>
        if includeArchived {
            descriptor = FetchDescriptor<TimelineModel>(sortBy: [SortDescriptor(\.createdAt)])
        } else {
            descriptor = FetchDescriptor<TimelineModel>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        }
        do {
            return try modelContext.fetch(descriptor).map { try $0.toThread() }
        } catch {
            Log.runtime.warning("failed to fetch all Threads", metadata: [
                "store": "TimelineStore",
            ])
            throw error
        }
    }

    public func deleteThread(id: UUID) async throws {
        try modelContext.delete(model: TimelineModel.self, where: #Predicate { $0.id == id })
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to delete Thread", metadata: [
                "store": "TimelineStore",
                "threadID": "\(id)",
            ])
            throw error
        }
    }

    public func pruneThreads(
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
            do {
                try modelContext.save()
            } catch {
                Log.runtime.error("failed to prune Timelines", metadata: [
                    "store": "TimelineStore",
                    "count": "\(candidates.count)",
                ])
                throw error
            }
        }
        return candidates.count
    }
}
