import Foundation

/// Identifies the timeline holding workspace-turn leases.
public struct WorkspaceTurnOwner: Sendable, Hashable {
    public let timelineID: UUID

    public init(timelineID: UUID) {
        self.timelineID = timelineID
    }
}

/// A releasable lease over all workspace/vault keys needed by one turn.
///
/// Release is idempotent. The caller MUST `await lease.release()` (typically via `defer` in the
/// turn's execution scope) so a thrown or cancelled turn never leaks a key — the scheduler does
/// not auto-release on deallocation.
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

/// Serializes turns that share an agent vault or an attached workspace (ATW-6, spec §5.2).
///
/// A turn acquires **all** of its keys (sorted by UUID for global lock ordering → deadlock-free)
/// before running; `release(keys:)` runs deferred on completion, failure, or cancellation. Per-key
/// FIFO waiters yield fairness: contending timelines interleave in arrival order, no starvation.
///
/// Terminal sessions are not serialized here (spec §5.3) — only the turns. `TerminalSessionRegistry`
/// keeps PTY sessions alive across timeline switches independently of turn scheduling.
public actor WorkspaceTurnScheduler {
    /// The current owner of each held key.
    private var holders: [UUID: WorkspaceTurnOwner] = [:]
    /// Per-key FIFO queue of waiters. A waiter is resumed (in enqueue order) when its key frees;
    /// it then re-runs the all-or-nothing claim from the top, so a resumed waiter may re-queue if
    /// it still needs other held keys.
    private var waiters: [UUID: [(WorkspaceTurnOwner, CheckedContinuation<Void, Error>)]] = [:]

    public init() {}

    /// Acquires a lease over all `keys` for `owner`, suspending until every key is available.
    /// Sorts keys by UUID for deadlock-free multi-key acquisition. Release is the caller's
    /// responsibility (`WorkspaceTurnLease.release()`).
    ///
    /// Cancellation: if the calling task is cancelled while suspended, the acquire throws
    /// `CancellationError`, the waiter is removed from every key's queue, and no lease is
    /// returned — so a cancelled turn holds no keys and needs no release.
    public func acquire(keys: [UUID], owner: WorkspaceTurnOwner) async throws -> WorkspaceTurnLease {
        let sortedKeys = Array(Set(keys)).sorted { $0.uuidString < $1.uuidString }
        guard !sortedKeys.isEmpty else {
            return WorkspaceTurnLease { /* nothing to release */ }
        }

        // All-or-nothing claim loop. Each iteration tries to claim every key; if any is held by
        // another owner, it releases the keys claimed this round and suspends on the first
        // contended key. On wake it retries from the top. FIFO is preserved because a waiter is
        // resumed in enqueue order and re-checks `holders` atomically within the actor.
        while true {
            try Task.checkCancellation()

            // Fast path: claim every key that's free and not already ours.
            var claimedThisRound: [UUID] = []
            var firstContended: UUID?
            for key in sortedKeys {
                if let existing = holders[key], existing != owner {
                    firstContended = key
                    break
                }
                holders[key] = owner
                claimedThisRound.append(key)
            }

            if firstContended == nil {
                // All keys held by `owner`. Done.
                return WorkspaceTurnLease { [weak self] in
                    await self?.release(keys: sortedKeys, owner: owner)
                }
            }

            // Roll back this round's partial claims so a suspended waiter doesn't hold a key
            // another waiter could use — re-claim them on retry.
            for key in claimedThisRound where holders[key] == owner {
                holders[key] = nil
            }
            // After freeing, wake any waiters on those keys so a different owner can proceed
            // (they'll re-run their own claim loops; if they still need `firstContended` they
            // re-queue).
            for key in claimedThisRound {
                wakeFrontWaiter(forKey: key)
            }

            // Suspend on the first contended key until released. Re-check cancellation on wake
            // so a cancelled acquire never returns a lease.
            let contended = firstContended!
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters[contended, default: []].append((owner, continuation))
                }
            } onCancel: {
                // The cancellation handler runs synchronously on cancellation; it cannot touch
                // actor state directly. Re-enter the actor to remove this owner's waiter (if still
                // queued) and resume it throwing so the suspended acquire unblocks and exits.
                Task { [weak self] in
                    await self?.cancelWaiter(owner: owner, forKey: contended)
                }
            }
            // Loop: retry the full claim.
        }
    }

    /// Removes and resumes-with-failure any waiter queued for `owner` on `key`, so a cancelled
    /// `acquire` suspends no longer and throws `CancellationError` out of its continuation. No-op
    /// if the owner already received the key (was resumed normally) — in that case its
    /// continuation is gone from the queue.
    private func cancelWaiter(owner: WorkspaceTurnOwner, forKey key: UUID) {
        guard var queue = waiters[key] else { return }
        if let index = queue.firstIndex(where: { $0.0 == owner }) {
            let (_, continuation) = queue.remove(at: index)
            waiters[key] = queue.isEmpty ? nil : queue
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Non-suspending attempt: returns a lease if all keys are free right now, otherwise `nil`
    /// (and holds nothing). Used by `ChatViewModel` for the uncontended fast path so the common
    /// turn never flashes a `.waitingForWorkspace` state.
    public func tryAcquire(keys: [UUID], owner: WorkspaceTurnOwner) -> WorkspaceTurnLease? {
        let sortedKeys = Array(Set(keys)).sorted { $0.uuidString < $1.uuidString }
        guard !sortedKeys.isEmpty else {
            return WorkspaceTurnLease { /* nothing to release */ }
        }
        for key in sortedKeys {
            if let existing = holders[key], existing != owner {
                return nil
            }
        }
        for key in sortedKeys {
            holders[key] = owner
        }
        return WorkspaceTurnLease { [weak self] in
            await self?.release(keys: sortedKeys, owner: owner)
        }
    }

    /// Releases all of `owner`'s keys and wakes the front waiter on each freed key so it can
    /// retry its claim. No-op for keys not held by `owner` (a partial/rolled-back acquire).
    private func release(keys: [UUID], owner: WorkspaceTurnOwner) {
        for key in keys where holders[key] == owner {
            holders[key] = nil
            wakeFrontWaiter(forKey: key)
        }
    }

    /// Resumes the front waiter on `key` (FIFO), if any. The resumed waiter re-runs its own
    /// `acquire` claim loop; it does not inherit the key directly.
    private func wakeFrontWaiter(forKey key: UUID) {
        guard var queue = waiters[key], !queue.isEmpty else { return }
        let (_, continuation) = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        continuation.resume()
    }

    /// Test/inspection helper: the owner currently holding `key`, if any. Not used by the turn
    /// path; lets tests assert "a cancelled/waiting turn holds no keys".
    public func holder(forKey key: UUID) -> WorkspaceTurnOwner? {
        holders[key]
    }

    /// Test/inspection helper: count of waiters queued on `key`.
    public func waiterCount(forKey key: UUID) -> Int {
        waiters[key]?.count ?? 0
    }
}
