import Foundation
import Testing
@testable import YakamozCore

/// ATW-6: actor-level tests for `WorkspaceTurnScheduler` — per-key FIFO fairness, sorted
/// multi-key acquisition (deadlock-free), and lock release on throw / cancellation. No UI, no
/// SwiftData. Spec §5.2–§5.3.
@Suite("WorkspaceTurnScheduler")
struct WorkspaceTurnSchedulerTests {
    /// Three owners acquire the same single key in enqueue order; their protected sections
    /// must run in that FIFO order (spec §5.2: "contending timelines interleave in arrival
    /// order; no starvation"). Tests assert arrival ordering, not literal round-robin.
    @Test("FIFO ordering for one contended key")
    func fifoOrderingForOneKey() async throws {
        let scheduler = WorkspaceTurnScheduler()
        let key = UUID()
        let recorder = OrderRecorder()
        let queued = AsyncCounter()

        let ownerA = WorkspaceTurnOwner(timelineID: UUID())
        let ownerB = WorkspaceTurnOwner(timelineID: UUID())
        let ownerC = WorkspaceTurnOwner(timelineID: UUID())

        // A acquires and holds until both B and C have queued behind it.
        async let a: Void = holdAndRecord(scheduler, owner: ownerA, key: key, tag: "A", recorder: recorder, releaseAfter: queued, releaseWhen: 2)
        await waitUntilHolder(scheduler, key: key)

        async let b: Void = acquireRecordRelease(scheduler, owner: ownerB, key: key, tag: "B", recorder: recorder)
        try await waitForWaiterCount(scheduler, key: key, count: 1)

        async let c: Void = acquireRecordRelease(scheduler, owner: ownerC, key: key, tag: "C", recorder: recorder)
        try await waitForWaiterCount(scheduler, key: key, count: 2)

        queued.increment()
        queued.increment()
        _ = await a
        _ = await b
        _ = await c

        #expect(recorder.snapshot() == ["A", "B", "C"])
    }

    /// Two owners with disjoint keys run concurrently without blocking each other (spec §5.2:
    /// disjoint workspace turns proceed independently).
    @Test("No blocking for disjoint keys")
    func noBlockingForDisjointKeys() async {
        let scheduler = WorkspaceTurnScheduler()
        let keyA = UUID()
        let keyB = UUID()
        let recorder = OrderRecorder()

        async let a = acquireRecordRelease(scheduler, owner: WorkspaceTurnOwner(timelineID: UUID()), key: keyA, tag: "A", recorder: recorder)
        async let b = acquireRecordRelease(scheduler, owner: WorkspaceTurnOwner(timelineID: UUID()), key: keyB, tag: "B", recorder: recorder)

        // Both complete without either waiting on the other.
        _ = await a
        _ = await b
        #expect(Set(recorder.snapshot()) == ["A", "B"])
    }

    /// Two owners each need keys A+B (overlapping need). Sorted-UUID acquisition order means
    /// neither can hold one key and wait on another the other holds → no deadlock; both complete.
    @Test("Sorted multi-key acquisition is deadlock-free")
    func sortedMultiKeyAcquisition() async throws {
        let scheduler = WorkspaceTurnScheduler()
        let keyA = UUID()
        let keyB = UUID()
        let firstKey = [keyA, keyB].sorted { $0.uuidString < $1.uuidString }.first!
        let recorder = OrderRecorder()
        let queued = AsyncCounter()

        let owner1 = WorkspaceTurnOwner(timelineID: UUID())
        let owner2 = WorkspaceTurnOwner(timelineID: UUID())

        // Owner1 acquires both keys and holds until owner2 has queued on the contended key.
        async let o1: Void = holdAndRecord(scheduler, owner: owner1, key: keyA, extraKey: keyB, tag: "1", recorder: recorder, releaseAfter: queued, releaseWhen: 1)
        await waitUntilHolder(scheduler, key: keyA)

        async let o2: Void = acquireRecordRelease(scheduler, owner: owner2, key: keyA, extraKey: keyB, tag: "2", recorder: recorder)
        try await waitForWaiterCount(scheduler, key: firstKey, count: 1)

        queued.increment()
        _ = await o1
        _ = await o2
        #expect(recorder.snapshot() == ["1", "2"])
    }

    /// A turn that throws inside its protected section releases its lease via `defer`; the next
    /// waiter proceeds (spec: "release on failure").
    @Test("Lease releases after a thrown operation")
    func releaseAfterThrownOperation() async throws {
        let scheduler = WorkspaceTurnScheduler()
        let key = UUID()
        let recorder = OrderRecorder()
        let release1 = AsyncCounter()

        let owner1 = WorkspaceTurnOwner(timelineID: UUID())
        let owner2 = WorkspaceTurnOwner(timelineID: UUID())

        // Owner1 acquires, throws, and its `defer` releases the lease.
        async let o1: Void = try await acquireThrowRelease(
            scheduler,
            owner: owner1,
            key: key,
            recorder: recorder,
            tag: "1",
            releaseAfter: release1
        )
        await waitUntilHolder(scheduler, key: key)

        async let o2: Void = acquireRecordRelease(scheduler, owner: owner2, key: key, tag: "2", recorder: recorder)
        try await waitForWaiterCount(scheduler, key: key, count: 1)
        release1.increment()

        // owner1's task throws; swallow so the test body continues.
        _ = try? await o1
        _ = await o2
        #expect(recorder.snapshot() == ["1", "2"])
        // owner1 threw after entering its protected section and released the key.
        #expect(await scheduler.holder(forKey: key) == nil)
    }

    /// A turn cancelled while queued holds no keys afterward, and a later waiter proceeds
    /// (spec: "release after cancellation" — a cancelled acquire returns no lease).
    @Test("Cancelled acquire holds no keys and lets the next waiter proceed")
    func releaseAfterCancellation() async throws {
        let scheduler = WorkspaceTurnScheduler()
        let key = UUID()
        let recorder = OrderRecorder()

        let owner1 = WorkspaceTurnOwner(timelineID: UUID())
        let owner3 = WorkspaceTurnOwner(timelineID: UUID())
        let owner4 = WorkspaceTurnOwner(timelineID: UUID())

        // owner1 holds the key until owner3 has queued behind it.
        let release1 = AsyncCounter()
        async let hold: Void = holdAndRecord(scheduler, owner: owner1, key: key, tag: "1", recorder: recorder, releaseAfter: release1, releaseWhen: 1)
        await waitUntilHolder(scheduler, key: key)

        // owner3 queues behind owner1, then is cancelled mid-wait.
        let o3Task = Task<Void, Never> {
            _ = try? await scheduler.acquire(keys: [key], owner: owner3)
        }
        try await waitForWaiterCount(scheduler, key: key, count: 1)

        // owner4 also queues behind owner1 (after owner3).
        let o4Task = Task<Void, Never> {
            do {
                let lease = try await scheduler.acquire(keys: [key], owner: owner4)
                recorder.append("4")
                await lease.release()
            } catch {}
        }
        try await waitForWaiterCount(scheduler, key: key, count: 2)

        o3Task.cancel()
        _ = await o3Task.value
        // owner3 was cancelled while queued: it must not hold the key, and must be dequeued.
        #expect(await scheduler.holder(forKey: key)?.timelineID != owner3.timelineID)

        release1.increment()
        _ = await hold
        await o4Task.value
        // owner1 ran first; owner4 (queued after owner3) ran once owner1 released. owner3 never
        // recorded because it was cancelled before acquiring.
        #expect(recorder.snapshot() == ["1", "4"])
    }
}

// MARK: - Helpers

/// Records a sequence of string tags under a lock.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ tag: String) {
        lock.lock(); values.append(tag); lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Acquires `key` (+`extraKey`), records `tag`, then releases.
private func acquireRecordRelease(
    _ scheduler: WorkspaceTurnScheduler,
    owner: WorkspaceTurnOwner,
    key: UUID,
    extraKey: UUID? = nil,
    tag: String,
    recorder: OrderRecorder
) async {
    var keys = [key]
    if let extraKey { keys.append(extraKey) }
    do {
        let lease = try await scheduler.acquire(keys: keys, owner: owner)
        recorder.append(tag)
        await lease.release()
    } catch {
        // Cancellation: record nothing.
    }
}

/// Acquires `key`, records `tag`, throws — releasing the lease via `defer`. The release must hop
/// to the scheduler actor, so it is dispatched (not awaited inline) — but for test determinism
/// we await it before returning.
private func acquireThrowRelease(
    _ scheduler: WorkspaceTurnScheduler,
    owner: WorkspaceTurnOwner,
    key: UUID,
    recorder: OrderRecorder,
    tag: String,
    releaseAfter: AsyncCounter
) async throws {
    let lease = try await scheduler.acquire(keys: [key], owner: owner)
    recorder.append(tag)
    await releaseAfter.wait(until: 1)
    // Release before throwing so the lease is not leaked (the throw exits scope).
    await lease.release()
    throw NSError(domain: "ATW6Test", code: 1, userInfo: nil)
}

/// Acquires `key` (+`extraKey`) and holds until `releaseAfter` reaches `releaseWhen`, recording
/// `tag` on entry. Used to park an owner so a later owner queues behind it.
private func holdAndRecord(
    _ scheduler: WorkspaceTurnScheduler,
    owner: WorkspaceTurnOwner,
    key: UUID,
    extraKey: UUID? = nil,
    tag: String,
    recorder: OrderRecorder,
    releaseAfter: AsyncCounter,
    releaseWhen: Int
) async {
    var keys = [key]
    if let extraKey { keys.append(extraKey) }
    do {
        let lease = try await scheduler.acquire(keys: keys, owner: owner)
        recorder.append(tag)
        await releaseAfter.wait(until: releaseWhen)
        await lease.release()
    } catch {
        // Cancellation: ignore.
    }
}

/// Polls the scheduler's waiter count for `key` until it reaches `count`. The scheduler
/// exposes `waiterCount(forKey:)` for exactly this. Bounded by wall-clock time, not a yield
/// count: a fixed number of yields can elapse before a contending task even starts on a busy
/// CI host, letting later owners queue out of order. The timeout only makes a real bug fail
/// fast instead of hanging.
private func waitForWaiterCount(
    _ scheduler: WorkspaceTurnScheduler,
    key: UUID,
    count: Int,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        let actual = await scheduler.waiterCount(forKey: key)
        if actual >= count { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    let actual = await scheduler.waiterCount(forKey: key)
    Issue.record("waiter count for \(key) never reached \(count); was \(actual)")
}

/// Waits until `key` has a holder (an owner has entered its protected section). Bounded by
/// wall-clock time for the same reason as `waitForWaiterCount`.
private func waitUntilHolder(
    _ scheduler: WorkspaceTurnScheduler,
    key: UUID,
    timeout: Duration = .seconds(5)
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await scheduler.holder(forKey: key) != nil { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("no holder ever acquired key \(key)")
}
