import Foundation
import Testing
@testable import YakamozCore

@Suite("MonadSidebarPresentation")
struct MonadSidebarPresentationTests {
    @Test("builds an Agents section and a Templates section, each sorted by name")
    func sectionsSortedByName() {
        let zed = MonadAgentSummary(id: UUID(), kind: .instance, name: "Zed", description: "")
        let ann = MonadAgentSummary(id: UUID(), kind: .instance, name: "ann", description: "")
        let tmplB = MonadAgentSummary(id: UUID(), kind: .template, name: "B Template", description: "")
        let tmplA = MonadAgentSummary(id: UUID(), kind: .template, name: "a template", description: "")

        let sections = MonadSidebarPresentation.sections(instances: [zed, ann], templates: [tmplB, tmplA])

        #expect(sections.map(\.id) == [.instance, .template])
        #expect(sections[0].title == "Agents")
        #expect(sections[0].agents.map(\.name) == ["ann", "Zed"])
        #expect(sections[1].title == "Templates")
        #expect(sections[1].agents.map(\.name) == ["a template", "B Template"])
    }

    @Test("omits a section entirely when its kind has no items")
    func omitsEmptySections() {
        let instance = MonadAgentSummary(id: UUID(), kind: .instance, name: "Only", description: "")

        let sections = MonadSidebarPresentation.sections(instances: [instance], templates: [])

        #expect(sections.count == 1)
        #expect(sections.first?.id == .instance)
    }

    @Test("both empty produces no sections")
    func bothEmpty() {
        let sections = MonadSidebarPresentation.sections(instances: [], templates: [])
        #expect(sections.isEmpty)
    }
}
