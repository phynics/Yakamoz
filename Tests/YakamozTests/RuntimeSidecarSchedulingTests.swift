import Foundation
import PKShared
@testable import YakamozCore
import Testing

@Suite("YakamozRuntime sidecar scheduling")
struct RuntimeSidecarSchedulingTests {
    @Test("includes the title directive when the conversation has no title yet")
    func includesTitleDirectiveForUntitledConversation() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: nil,
            turnsSinceLastTitleDirective: 0
        )
        #expect(directives.map(\.name) == [TitleDirective.name])
    }

    @Test("omits the title directive when not due")
    func omitsTitleDirectiveWhenNotDue() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Existing Title",
            turnsSinceLastTitleDirective: 1
        )
        #expect(directives.isEmpty)
    }

    @Test("includes the title directive again once the interval elapses")
    func includesTitleDirectiveAtInterval() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Existing Title",
            turnsSinceLastTitleDirective: TitleSidecarSchedule.defaultInterval
        )
        #expect(directives.map(\.name) == [TitleDirective.name])
    }
}