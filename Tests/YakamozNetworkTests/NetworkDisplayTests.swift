import Foundation
import Testing
@testable import YakamozNetwork

@Suite("NetworkDisplay")
struct NetworkDisplayTests {
    // MARK: - Entity status

    @Test("Incompatibility outranks offline, which outranks a failed backend")
    func ascendantStatusPrecedence() {
        let key = TestEntities.key(UUID())
        let failedIncompatible = TestEntities.ascendant(key: key, name: "Ada", health: .failed, compatible: false)
        let failed = TestEntities.ascendant(key: key, name: "Ada", health: .failed)
        let healthy = TestEntities.ascendant(key: key, name: "Ada")

        #expect(NetworkEntityStatus.of(failedIncompatible, isOffline: true) == .incompatible(protocolMajor: 2))
        #expect(NetworkEntityStatus.of(failed, isOffline: true) == .offline)
        #expect(NetworkEntityStatus.of(failed, isOffline: false).label == "Degraded")
        #expect(NetworkEntityStatus.of(healthy, isOffline: false) == .live)
        #expect(NetworkEntityStatus.live.explanation == nil)
    }

    @Test("An unusable workspace is degraded with its effective-status description")
    func workspaceStatus() {
        let key = TestEntities.key(UUID())
        let unavailable = TestEntities.workspace(key: key, uri: "file:///w", effectiveStatus: .unsupported)

        #expect(NetworkEntityStatus.of(unavailable, isOffline: false)
            == .degraded(NetworkWorkspaceEffectiveStatus.unsupported.displayDescription))
        #expect(NetworkEntityStatus.of(TestEntities.workspace(key: key, uri: "file:///w"), isOffline: false) == .live)
    }

    // MARK: - Chat availability

    @Test("A disconnected client blocks sending before any timeline state")
    func disconnectedBlocks() {
        let availability = NetworkChatAvailability.resolve(
            connection: .connecting,
            status: .incompatible(protocolMajor: 9),
            isArchived: true
        )
        #expect(availability.reason?.contains("Not connected") == true)
    }

    @Test("Offline, incompatible, and archived timelines block; live and degraded are ready")
    func timelineStateBlocks() {
        #expect(NetworkChatAvailability.resolve(connection: .online, status: .offline, isArchived: false).reason != nil)
        #expect(NetworkChatAvailability.resolve(connection: .online, status: .incompatible(protocolMajor: nil), isArchived: false).reason != nil)
        #expect(NetworkChatAvailability.resolve(connection: .online, status: .live, isArchived: true).reason == "This timeline is archived.")
        #expect(NetworkChatAvailability.resolve(connection: .online, status: .live, isArchived: false) == .ready)
        #expect(NetworkChatAvailability.resolve(connection: .online, status: .degraded("x"), isArchived: false) == .ready)
    }

    // MARK: - Display strings

    @Test("Workspace display names prefer the last path component, then the host")
    func workspaceDisplayName() {
        let key = TestEntities.key(UUID())
        #expect(TestEntities.workspace(key: key, uri: "file:///Users/me/My%20Repo").displayName == "My Repo")
        #expect(TestEntities.workspace(key: key, uri: "gnostic://echo-host").displayName == "echo-host")
        #expect(TestEntities.workspace(key: key, uri: "not a uri").displayName == "not a uri")
    }

    @Test("Enum labels never leak raw values")
    func enumLabels() {
        #expect(NetworkWorkspaceTrustLevel.readOnly.displayName == "Read-only")
        #expect(NetworkBackendHealth.healthy.displayName == "Healthy")
        #expect(NetworkConnectionState.failed("boom").shortLabel == "Disconnected")
        #expect(NetworkConnectionState.retrying(attempt: 3, nextAttemptAt: nil).shortLabel == "Reconnecting…")
    }

    // MARK: - Catalog relationships

    @Test("A workspace lists every timeline it is attached to")
    func timelinesAttachedToWorkspace() {
        let workspaceID = UUID()
        let workspace = TestEntities.workspace(key: TestEntities.key(workspaceID, provider: "p1"), uri: "file:///w")
        let attached = NetworkTimelineRef(
            key: TestEntities.key(UUID(), provider: "p1"),
            title: "Attached",
            isArchived: false,
            isPrivate: false,
            attachedAscendantID: nil,
            attachedWorkspaceIDs: [workspaceID],
            provenance: NetworkProvenance(providerID: "p1"),
            compatibility: TestEntities.compatibility()
        )
        let detached = NetworkTimelineRef(
            key: TestEntities.key(UUID(), provider: "p2"),
            title: "Detached",
            isArchived: false,
            isPrivate: false,
            attachedAscendantID: nil,
            attachedWorkspaceIDs: [UUID()],
            provenance: NetworkProvenance(providerID: "p2"),
            compatibility: TestEntities.compatibility()
        )
        var catalog = NetworkCatalogState()
        catalog.apply(.discovered(.workspace(workspace)))
        catalog.apply(.discovered(.timeline(attached)))
        catalog.apply(.discovered(.timeline(detached)))

        #expect(catalog.timelines(attachedTo: workspace).map(\.title) == ["Attached"])
    }

    @Test("A timeline resolves its Ascendant only under the same provider")
    func ascendantForTimeline() {
        let ascendantID = UUID()
        let ascendant = TestEntities.ascendant(key: TestEntities.key(ascendantID, provider: "p1"), name: "Ada")
        let timeline = TestEntities.timeline(key: TestEntities.key(UUID(), provider: "p1"), title: "T", attachedAscendantID: ascendantID)
        let foreign = TestEntities.timeline(key: TestEntities.key(UUID(), provider: "p2"), title: "F", attachedAscendantID: ascendantID)
        var catalog = NetworkCatalogState()
        catalog.apply(.discovered(.ascendant(ascendant)))

        #expect(catalog.ascendant(for: timeline)?.name == "Ada")
        #expect(catalog.ascendant(for: foreign) == nil)
    }
}
