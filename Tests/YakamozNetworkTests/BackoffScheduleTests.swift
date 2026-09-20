import Foundation
import Testing
@testable import YakamozNetwork

@Suite("BackoffSchedule")
struct BackoffScheduleTests {
    @Test("Without jitter, delays grow by the factor")
    func growth() {
        let schedule = BackoffSchedule(base: 1, factor: 2, cap: 100, jitter: 0)
        #expect(schedule.delaySeconds(forAttempt: 1) == 1)
        #expect(schedule.delaySeconds(forAttempt: 2) == 2)
        #expect(schedule.delaySeconds(forAttempt: 3) == 4)
        #expect(schedule.delaySeconds(forAttempt: 4) == 8)
    }

    @Test("Delays are capped")
    func cap() {
        let schedule = BackoffSchedule(base: 1, factor: 2, cap: 5, jitter: 0)
        #expect(schedule.delaySeconds(forAttempt: 10) == 5)
    }

    @Test("Jitter stays within the configured band")
    func jitterBand() {
        let schedule = BackoffSchedule(base: 4, factor: 1, cap: 100, jitter: 0.5)
        let delay = schedule.delaySeconds(forAttempt: 3)
        #expect(delay >= 2 && delay <= 6)
    }

    @Test("The same seed produces the same sequence")
    func deterministic() {
        let first = BackoffSchedule(base: 1, factor: 2, cap: 60, jitter: 0.3, seed: 42)
        let second = BackoffSchedule(base: 1, factor: 2, cap: 60, jitter: 0.3, seed: 42)
        for attempt in 1 ... 6 {
            #expect(first.delaySeconds(forAttempt: attempt) == second.delaySeconds(forAttempt: attempt))
        }
    }

    @Test("Different seeds spread the sequence")
    func seedsDiffer() {
        let first = BackoffSchedule(base: 1, factor: 2, cap: 60, jitter: 0.3, seed: 1)
        let second = BackoffSchedule(base: 1, factor: 2, cap: 60, jitter: 0.3, seed: 2)
        let differs = (1 ... 6).contains {
            first.delaySeconds(forAttempt: $0) != second.delaySeconds(forAttempt: $0)
        }
        #expect(differs)
    }

    @Test("Attempts below one behave as the first attempt")
    func clampsAttempt() {
        let schedule = BackoffSchedule(base: 2, factor: 2, cap: 100, jitter: 0)
        #expect(schedule.delaySeconds(forAttempt: 0) == 2)
        #expect(schedule.delaySeconds(forAttempt: -5) == 2)
    }
}
