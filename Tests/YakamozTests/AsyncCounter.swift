import Foundation

/// A small lock/waiter/`CheckedContinuation` helper tests use to `await` async side
/// effects (e.g. "wait until the scripted runner has been invoked N times") without
/// wall-clock polling. Shared across test files to avoid drift between copies (STAB-14).
final class AsyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        let ready: [CheckedContinuation<Void, Never>]
        lock.lock()
        value += 1
        var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var matched: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters {
            if value >= waiter.target {
                matched.append(waiter.continuation)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        ready = matched
        lock.unlock()

        for continuation in ready {
            continuation.resume()
        }
    }

    func wait(until target: Int) async {
        if hasReached(target) {
            return
        }

        await withCheckedContinuation { continuation in
            enqueue(continuation, until: target)
        }
    }

    private func hasReached(_ target: Int) -> Bool {
        lock.lock()
        if value >= target {
            lock.unlock()
            return true
        }
        lock.unlock()
        return false
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>, until target: Int) {
        lock.lock()
        if value >= target {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append((target, continuation))
            lock.unlock()
        }
    }
}
