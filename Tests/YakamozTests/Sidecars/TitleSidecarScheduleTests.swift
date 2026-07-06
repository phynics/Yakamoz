import Foundation
import Testing
@testable import YakamozCore

@Suite("TitleSidecarSchedule")
struct TitleSidecarScheduleTests {
    @Test("no title yet: directive is due every turn")
    func dueWhenNoTitle() {
        #expect(TitleSidecarSchedule.isDue(hasTitle: false, turnsSinceLastTitle: 0, interval: 5))
        #expect(TitleSidecarSchedule.isDue(hasTitle: false, turnsSinceLastTitle: 3, interval: 5))
    }

    @Test("title present, under interval: not due")
    func notDueUnderInterval() {
        #expect(!TitleSidecarSchedule.isDue(hasTitle: true, turnsSinceLastTitle: 1, interval: 5))
        #expect(!TitleSidecarSchedule.isDue(hasTitle: true, turnsSinceLastTitle: 4, interval: 5))
    }

    @Test("title present, at or past interval: due")
    func dueAtInterval() {
        #expect(TitleSidecarSchedule.isDue(hasTitle: true, turnsSinceLastTitle: 5, interval: 5))
        #expect(TitleSidecarSchedule.isDue(hasTitle: true, turnsSinceLastTitle: 9, interval: 5))
    }

    @Test("default interval is a sensible positive number")
    func defaultIntervalIsSensible() {
        #expect(TitleSidecarSchedule.defaultInterval > 0)
    }
}
