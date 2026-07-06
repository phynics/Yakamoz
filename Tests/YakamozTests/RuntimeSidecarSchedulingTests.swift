import Foundation
import PKShared
@testable import YakamozCore
import Testing

@Suite("YakamozRuntime sidecar scheduling")
struct RuntimeSidecarSchedulingTests {
    @Test("includes the title directive when the conversation has no title yet, plus section_title")
    func includesTitleDirectiveForUntitledConversation() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: nil,
            turnsSinceLastTitleDirective: 0,
            currentSectionTitle: nil
        )
        #expect(directives.map(\.name) == [TitleDirective.name, SectionTitleDirective.name])
    }

    @Test("omits the title directive when not due, but still includes section_title")
    func omitsTitleDirectiveWhenNotDue() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Existing Title",
            turnsSinceLastTitleDirective: 1,
            currentSectionTitle: "Exploring"
        )
        #expect(directives.map(\.name) == [SectionTitleDirective.name])
    }

    @Test("includes the title directive again once the interval elapses, alongside section_title")
    func includesTitleDirectiveAtInterval() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Existing Title",
            turnsSinceLastTitleDirective: TitleSidecarSchedule.defaultInterval,
            currentSectionTitle: nil
        )
        #expect(directives.map(\.name) == [TitleDirective.name, SectionTitleDirective.name])
    }

    @Test("section_title directive embeds the current section title when supplied")
    func sectionTitleDirectiveEmbedsCurrentSection() {
        let directives = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Title",
            turnsSinceLastTitleDirective: 0,
            currentSectionTitle: "Debugging"
        )
        let sectionDirective = directives.first { $0.name == SectionTitleDirective.name }
        #expect(sectionDirective?.instruction.contains("Debugging") == true)
    }

    @Test("section_title directive is included even when the conversation has no title yet (no cadence gating)")
    func sectionTitleAlwaysIncludedRegardlessOfTitleCadence() {
        // No title yet (title directive due) — section_title still rides alongside.
        let a = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: nil,
            turnsSinceLastTitleDirective: 0,
            currentSectionTitle: nil
        )
        #expect(a.contains { $0.name == SectionTitleDirective.name })

        // Title directive not due — section_title still rides.
        let b = YakamozRuntime.dueSidecarDirectives(
            conversationTitle: "Title",
            turnsSinceLastTitleDirective: 2,
            currentSectionTitle: nil
        )
        #expect(b.contains { $0.name == SectionTitleDirective.name })
    }
}