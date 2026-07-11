import Foundation

/// Identifies the timeline holding workspace-turn leases.
public struct WorkspaceTurnOwner: Sendable, Hashable {
    public let timelineID: UUID

    public init(timelineID: UUID) { self.timelineID = timelineID }
}

/// A releasable lease over all workspace/vault keys needed by one turn.
public final class WorkspaceTurnLease: @unchecked Sendable {
    private let releaseAction: @Sendable () async -> Void
    private var released = false

    fileprivate init(releaseAction: @escaping @Sendable () async -> Void) {
        self.releaseAction = releaseAction
    }

    public func release() async {
        guard !released else { return }
        released = true
        await releaseAction()
    }
}

/// Serializes turns that share an agent vault or attached workspace.
public actor WorkspaceTurnScheduler {
    private var holders: [UUID: WorkspaceTurnOwner] = [:]

    public init() {}

    public func acquire(keys: [UUID], owner: WorkspaceTurnOwner) async -> WorkspaceTurnLease {
        let sortedKeys = Array(Set(keys)).sorted { $0.uuidString < $1.uuidString }
        while sortedKeys.contains(where: { holders[$0] != nil }) {
            await Task.yield()
        }
        for key in sortedKeys { holders[key] = owner }
        return WorkspaceTurnLease { [weak self] in
            await self?.release(keys: sortedKeys, owner: owner)
        }
    }

    private func release(keys: [UUID], owner: WorkspaceTurnOwner) {
        for key in keys where holders[key] == owner {
            holders[key] = nil
        }
    }
}
