import Foundation
import GnosticCore
import Testing
@testable import YakamozNetwork

/// Pins the GnosticCore -> module-local mapping performed by
/// ``GnosticCoreTransport``. This is the one test file that imports
/// `GnosticCore`: it builds `NetworkCatalogEntry` fixtures directly, so the
/// mapping is covered without a broker or a live subscription.
@Suite("GnosticCoreTransport mapping")
@MainActor
struct GnosticCoreTransportMappingTests {
    private let providerID = "provider.one"

    private func entry(
        objectType: String,
        objectID: UUID = UUID(),
        name: String = "object",
        protocolMajor: Int? = GnosticProtocol.currentMajor,
        isProtocolCompatible: Bool? = nil,
        knownProperties: [String: NetworkDynamicValue] = [:],
        workspace: NetworkWorkspaceDescriptor? = nil,
        effectiveStatus: GnosticWorkspaceEffectiveStatus? = nil
    ) -> NetworkCatalogEntry {
        NetworkCatalogEntry(
            objectID: objectID,
            objectType: objectType,
            protocolMajor: protocolMajor,
            isProtocolCompatible: isProtocolCompatible,
            providerID: providerID,
            name: name,
            knownProperties: knownProperties,
            dynamicProperties: [:],
            workspace: workspace,
            effectiveStatus: effectiveStatus
        )
    }

    @Test("An Ascendant advertisement maps every known projection field")
    func mapsAscendant() {
        let objectID = UUID()
        let nodeID = UUID()
        let mapped = GnosticCoreTransport.map(
            entry(
                objectType: GnosticObjectType.ascendant,
                objectID: objectID,
                name: "Atlas",
                knownProperties: [
                    "ascendantDescription": .string("a remote ascendant"),
                    "capabilities": .array([.string("me.atkn.gnostic.capability.turn.text"), .integer(7)]),
                    "backendHealth": .string("healthy"),
                    "backendKind": .string("positronic"),
                    "backendVersion": .string("6.0.0"),
                    "nodeID": .string(nodeID.uuidString),
                ]
            )
        )

        guard case let .ascendant(ascendant) = mapped else {
            Issue.record("expected an ascendant, got \(String(describing: mapped))")
            return
        }
        #expect(ascendant.key == NetworkObjectKey(objectID: objectID, providerID: providerID))
        #expect(ascendant.name == "Atlas")
        #expect(ascendant.summary == "a remote ascendant")
        // Non-string array members are dropped rather than coerced.
        #expect(ascendant.capabilities == ["me.atkn.gnostic.capability.turn.text"])
        #expect(ascendant.backendHealth == .healthy)
        #expect(ascendant.backendKind == "positronic")
        #expect(ascendant.backendVersion == "6.0.0")
        #expect(ascendant.provenance.providerID == providerID)
        #expect(ascendant.provenance.nodeID == nodeID)
        #expect(ascendant.compatibility.isCompatible)
    }

    @Test("Absent Ascendant properties fall back rather than crash")
    func mapsSparseAscendant() {
        let mapped = GnosticCoreTransport.map(
            entry(objectType: GnosticObjectType.ascendant, name: "Bare")
        )

        guard case let .ascendant(ascendant) = mapped else {
            Issue.record("expected an ascendant, got \(String(describing: mapped))")
            return
        }
        #expect(ascendant.summary.isEmpty)
        #expect(ascendant.capabilities.isEmpty)
        #expect(ascendant.backendHealth == .unknown)
        #expect(ascendant.backendKind == nil)
        #expect(ascendant.backendVersion == nil)
        #expect(ascendant.provenance.nodeID == nil)
    }

    @Test("A Timeline advertisement maps its attachments")
    func mapsTimeline() {
        let ascendantID = UUID()
        let workspaceID = UUID()
        let mapped = GnosticCoreTransport.map(
            entry(
                objectType: GnosticObjectType.timeline,
                name: "timeline-object",
                knownProperties: [
                    "title": .string("Release plan"),
                    "isArchived": .bool(true),
                    "isPrivate": .bool(true),
                    "attachedAscendantID": .string(ascendantID.uuidString),
                    "attachedWorkspaceIDs": .array([.string(workspaceID.uuidString), .string("not-a-uuid")]),
                ]
            )
        )

        guard case let .timeline(timeline) = mapped else {
            Issue.record("expected a timeline, got \(String(describing: mapped))")
            return
        }
        #expect(timeline.title == "Release plan")
        #expect(timeline.isArchived)
        #expect(timeline.isPrivate)
        #expect(timeline.attachedAscendantID == ascendantID)
        // Malformed identifiers are dropped, not substituted.
        #expect(timeline.attachedWorkspaceIDs == [workspaceID])
    }

    @Test("A Timeline without a title falls back to the Axoloty object name")
    func mapsTimelineWithoutTitle() {
        let mapped = GnosticCoreTransport.map(
            entry(objectType: GnosticObjectType.timeline, name: "timeline-object")
        )

        guard case let .timeline(timeline) = mapped else {
            Issue.record("expected a timeline, got \(String(describing: mapped))")
            return
        }
        #expect(timeline.title == "timeline-object")
        #expect(!timeline.isArchived)
        #expect(!timeline.isPrivate)
        #expect(timeline.attachedAscendantID == nil)
        #expect(timeline.attachedWorkspaceIDs.isEmpty)
    }

    @Test("A well-formed Workspace maps its descriptor")
    func mapsWorkspace() {
        let workspaceID = UUID()
        let tool = GnosticWorkspaceTool(
            definition: GnosticWorkspaceToolDefinition(id: "grep", name: "Grep", description: "search")
        )
        let descriptor = NetworkWorkspaceDescriptor(
            id: workspaceID,
            uri: "file:///remote/project",
            isAvailable: true,
            trustLevel: .restricted,
            status: .active,
            tools: [tool]
        )
        let mapped = GnosticCoreTransport.map(
            entry(
                objectType: GnosticObjectType.workspace,
                objectID: workspaceID,
                name: "workspace-object",
                workspace: descriptor
            )
        )

        guard case let .workspace(workspace) = mapped else {
            Issue.record("expected a workspace, got \(String(describing: mapped))")
            return
        }
        #expect(workspace.uri == "file:///remote/project")
        #expect(workspace.trustLevel == .restricted)
        #expect(workspace.status == .active)
        #expect(workspace.effectiveStatus == .available)
        #expect(workspace.isAvailable)
        #expect(workspace.toolNames == ["Grep"])
    }

    @Test("A malformed Workspace keeps the entry's effective status and fails trust closed")
    func mapsMalformedWorkspace() {
        let mapped = GnosticCoreTransport.map(
            entry(
                objectType: GnosticObjectType.workspace,
                name: "workspace-object",
                workspace: nil,
                effectiveStatus: .unsupported
            )
        )

        guard case let .workspace(workspace) = mapped else {
            Issue.record("expected a workspace, got \(String(describing: mapped))")
            return
        }
        #expect(workspace.uri == "workspace-object")
        // No advertised boundary must never read as unrestricted.
        #expect(workspace.trustLevel == .readOnly)
        #expect(workspace.status == .unknown)
        #expect(workspace.effectiveStatus == .unsupported)
        #expect(!workspace.isAvailable)
        #expect(workspace.toolNames.isEmpty)
    }

    @Test("An incompatible protocol major is retained and flagged, not dropped")
    func retainsIncompatibleEntries() {
        let mapped = GnosticCoreTransport.map(
            entry(
                objectType: GnosticObjectType.ascendant,
                name: "Future",
                protocolMajor: GnosticProtocol.currentMajor + 1,
                isProtocolCompatible: false
            )
        )

        guard case let .ascendant(ascendant) = mapped else {
            Issue.record("expected an ascendant, got \(String(describing: mapped))")
            return
        }
        #expect(ascendant.compatibility.protocolMajor == GnosticProtocol.currentMajor + 1)
        #expect(!ascendant.compatibility.isCompatible)
    }

    @Test("Workspace tools and unrecognized types are skipped, never crashed on")
    func skipsUnlistedTypes() {
        #expect(GnosticCoreTransport.map(entry(objectType: GnosticObjectType.workspaceTool)) == nil)
        #expect(GnosticCoreTransport.map(entry(objectType: "me.atkn.gnostic.SomethingNew")) == nil)
        #expect(GnosticCoreTransport.map(entry(objectType: "")) == nil)
    }
}
