import Foundation
import Testing
@testable import YakamozNetwork

@Suite("NetworkCatalogState")
struct NetworkCatalogStateTests {
    private let ascendantID = UUID()
    private let timelineID = UUID()
    private let workspaceID = UUID()

    @Test("Advertise adds each kind to its bucket")
    func advertiseAdds() {
        var catalog = NetworkCatalogState()
        let ascendantKey = TestEntities.key(ascendantID)
        let ascendant = TestEntities.ascendant(key: ascendantKey, name: "Ada")

        catalog.apply(.discovered(.ascendant(ascendant)))
        catalog.apply(.discovered(.timeline(TestEntities.timeline(key: TestEntities.key(timelineID), title: "T", attachedAscendantID: ascendantID))))
        catalog.apply(.discovered(.workspace(TestEntities.workspace(key: TestEntities.key(workspaceID), uri: "ws://one"))))

        #expect(catalog.ascendants[ascendantKey] == ascendant)
        #expect(catalog.timelines.count == 1)
        #expect(catalog.workspaces.count == 1)
        #expect(!catalog.isEmpty)
    }

    @Test("Re-advertising the same key replaces the snapshot")
    func duplicateAdvertiseReplaces() {
        var catalog = NetworkCatalogState()
        let key = TestEntities.key(ascendantID)

        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Old"))))
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "New"))))

        #expect(catalog.ascendants.count == 1)
        #expect(catalog.ascendants[key]?.name == "New")
    }

    @Test("Deadvertise removes only the addressed provider-scoped object")
    func deadvertiseRemovesOne() {
        var catalog = NetworkCatalogState()
        let removedKey = TestEntities.key(ascendantID, provider: "p1")
        let keptKey = TestEntities.key(ascendantID, provider: "p2")

        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: removedKey, name: "Removed"))))
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: keptKey, name: "Kept"))))
        catalog.apply(.deadvertised(removedKey))

        #expect(catalog.ascendants[removedKey] == nil)
        #expect(catalog.ascendants[keptKey] != nil)
    }

    @Test("Provider eviction clears that provider only")
    func providerEvictionClearsOneProvider() {
        var catalog = NetworkCatalogState()
        let firstKey = TestEntities.key(ascendantID, provider: "p1")
        let secondKey = TestEntities.key(ascendantID, provider: "p2")

        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: firstKey, name: "First"))))
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: secondKey, name: "Second"))))
        catalog.apply(.providerEvicted(providerID: "p1"))

        #expect(catalog.ascendants[firstKey] == nil)
        #expect(catalog.ascendants[secondKey] != nil)
    }

    @Test("Incompatible objects are retained and flagged, never dropped")
    func incompatibleRetained() {
        var catalog = NetworkCatalogState()
        let key = TestEntities.key(ascendantID)

        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Legacy", compatible: false))))

        #expect(catalog.ascendants.count == 1)
        #expect(catalog.ascendants[key]?.compatibility.isCompatible == false)
    }

    @Test("Timelines are grouped under their attached Ascendant within one provider")
    func timelinesForAscendant() {
        var catalog = NetworkCatalogState()
        let ascendantKey = TestEntities.key(ascendantID, provider: "p1")
        let attached = TestEntities.key(timelineID, provider: "p1")
        let otherProvider = TestEntities.key(UUID(), provider: "p2")
        let unattached = TestEntities.key(UUID(), provider: "p1")

        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: ascendantKey, name: "Ada"))))
        catalog.apply(.discovered(.timeline(TestEntities.timeline(key: attached, title: "Attached", attachedAscendantID: ascendantID))))
        catalog.apply(.discovered(.timeline(TestEntities.timeline(key: unattached, title: "Loose"))))
        catalog.apply(.discovered(.timeline(TestEntities.timeline(key: otherProvider, title: "Other", attachedAscendantID: ascendantID))))

        let grouped = catalog.timelines(forAscendant: ascendantKey).map(\.key)
        #expect(grouped == [attached])
    }

    @Test("object(for:) resolves whichever kind holds the key")
    func objectLookup() {
        var catalog = NetworkCatalogState()
        let key = TestEntities.key(workspaceID)
        let workspace = TestEntities.workspace(key: key, uri: "ws://one")

        catalog.apply(.discovered(.workspace(workspace)))

        #expect(catalog.object(for: key) == .workspace(workspace))
        #expect(catalog.object(for: TestEntities.key(UUID())) == nil)
    }

    @Test("Connection-lost events leave the catalog untouched")
    func connectionLostIgnored() {
        var catalog = NetworkCatalogState()
        let key = TestEntities.key(ascendantID)
        catalog.apply(.discovered(.ascendant(TestEntities.ascendant(key: key, name: "Ada"))))

        catalog.apply(.connectionLost(reason: "boom"))

        #expect(catalog.ascendants.count == 1)
    }
}
