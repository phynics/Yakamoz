import Foundation
import Testing
@testable import YakamozNetwork

@Suite("NetworkSidebarPresentation")
struct NetworkSidebarPresentationTests {
    @Test("A live Ascendant groups its advertised Timelines and the Workspaces list")
    func groupsAscendantWithTimelines() {
        let ascendantID = UUID()
        let ascendantKey = TestEntities.key(ascendantID, provider: "p1")
        let timelineKey = TestEntities.key(UUID(), provider: "p1")
        var catalog = NetworkCatalogState()
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: ascendantKey, name: "Ada"))))
        catalog.apply(.discovered(.timeline(TestEntities.timeline(key: timelineKey, title: "Chat", attachedAscendantID: ascendantID))))
        catalog.apply(.discovered(.workspace(TestEntities.workspace(key: TestEntities.key(UUID(), provider: "p1"), uri: "ws://one"))))

        let group = NetworkSidebarPresentation.group(catalog: catalog)

        #expect(group.ascendants.count == 1)
        #expect(group.ascendants.first?.isOffline == false)
        #expect(group.ascendants.first?.timelines.map(\.key) == [timelineKey])
        #expect(group.workspaces.count == 1)
        #expect(group.looseTimelines.isEmpty)
        #expect(!group.isEmpty)
    }

    @Test("A deadvertised-but-open entry renders offline/reconnectable")
    func deadvertisedOpenRendersOffline() {
        let ascendantID = UUID()
        let ascendantKey = TestEntities.key(ascendantID, provider: "p1")
        let timelineKey = TestEntities.key(UUID(), provider: "p1")
        let ascendant = TestEntities.ascendant(key: ascendantKey, name: "Ada")
        let timeline = TestEntities.timeline(key: timelineKey, title: "Chat", attachedAscendantID: ascendantID)

        let group = NetworkSidebarPresentation.group(
            catalog: NetworkCatalogState(),
            openSessions: [ascendantKey: .ascendant(ascendant), timelineKey: .timeline(timeline)]
        )

        #expect(group.ascendants.count == 1)
        #expect(group.ascendants.first?.isOffline == true)
        #expect(group.ascendants.first?.timelines.map(\.key) == [timelineKey])
        #expect(group.isOffline(ascendantKey))
        #expect(group.isOffline(timelineKey))
    }

    @Test("An open timeline with no listed Ascendant becomes a loose timeline")
    func looseTimeline() {
        let timelineKey = TestEntities.key(UUID())
        let timeline = TestEntities.timeline(key: timelineKey, title: "Orphan", attachedAscendantID: nil)

        let group = NetworkSidebarPresentation.group(
            catalog: NetworkCatalogState(),
            openSessions: [timelineKey: .timeline(timeline)]
        )

        #expect(group.ascendants.isEmpty)
        #expect(group.looseTimelines.map(\.key) == [timelineKey])
        #expect(group.isOffline(timelineKey))
    }

    @Test("An empty catalog with no open sessions is empty")
    func emptyCatalog() {
        let group = NetworkSidebarPresentation.group(catalog: NetworkCatalogState())
        #expect(group.isEmpty)
        #expect(group.ascendants.isEmpty)
        #expect(group.workspaces.isEmpty)
        #expect(group.looseTimelines.isEmpty)
    }

    @Test("Ascendants are ordered by name")
    func ordering() {
        var catalog = NetworkCatalogState()
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: TestEntities.key(UUID()), name: "zed"))))
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: TestEntities.key(UUID()), name: "Ada"))))

        let group = NetworkSidebarPresentation.group(catalog: catalog)

        #expect(group.ascendants.map(\.ascendant.name) == ["Ada", "zed"])
    }

    @Test("Selections are Hashable and distinct per kind")
    func selectionHashing() {
        let key = TestEntities.key(UUID())
        let selections: Set<NetworkSidebarSelection> = [.ascendant(key), .timeline(key), .workspace(key)]
        #expect(selections.count == 3)
    }
}
