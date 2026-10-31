import Foundation
import GnosticClient
import GnosticCore
import GnosticProtocol
import Testing
@testable import YakamozNetwork

/// The Gnostic-typed half of the opt-in live tests. It lives here because this is the
/// one test file allowed to import a Gnostic module.
@MainActor
enum GnosticLiveProbe {
    /// Invokes one Workspace tool, detaches the Workspace, and returns the tool's result.
    static func invokeAndDetach(
        workspaceID: UUID,
        timelineID: UUID,
        toolID: String,
        value: String,
        host: String,
        port: Int,
        namespace: String
    ) async throws -> (isSuccess: Bool, output: String) {
        let session = try await startedSession(identity: "yakamoz-live-smoke-invoke", host: host, port: port, namespace: namespace)
        do {
            let client = try session.workspaceClient(timeout: .seconds(5))
            let result = try await client.invoke(
                timelineID: timelineID,
                workspaceID: workspaceID,
                toolID: toolID,
                arguments: ["value": .string(value)]
            )
            try await client.detach(workspaceID: workspaceID, from: timelineID)
            await session.stop()
            return (result.isSuccess, result.output)
        } catch {
            await session.stop()
            throw error
        }
    }

    /// One line per catalog record: object type, protocol major, and every known property.
    static func advertisedObjects(host: String, port: Int, namespace: String) async throws -> [String] {
        let session = try await startedSession(identity: "yakamoz-live-discovery-raw", host: host, port: port, namespace: namespace)
        let entries = await session.networkObjects(includeIncompatible: true)
        await session.stop()
        return entries.map { entry in
            let properties = entry.knownProperties.keys.sorted().map { "\($0)=\(entry.knownProperties[$0]!)" }
            return "objectType=\(entry.objectType) name=\(entry.name) protocolMajor=\(entry.protocolMajor.map(String.init) ?? "nil") compatible=\(entry.isProtocolCompatible) dynamicKeys=\(entry.dynamicProperties.keys.sorted()) \(properties.joined(separator: " "))"
        }
    }

    private static func startedSession(identity: String, host: String, port: Int, namespace: String) async throws -> GnosticConsumerSession {
        let session = try GnosticConsumerSession(
            broker: GnosticBrokerSettings(host: host, port: port, namespace: namespace),
            identityName: identity
        )
        try await session.start()
        do {
            try await session.discover()
        } catch {
            await session.stop()
            throw error
        }
        return session
    }
}

/// Pins the Gnostic -> module-local mapping performed by
/// ``LiveGnosticClientTransport``. This is the one test file that imports a Gnostic
/// module: it builds `NetworkCatalogEntry` fixtures directly, so the mapping is covered
/// without a broker or a live subscription.
@Suite("LiveGnosticClientTransport mapping")
@MainActor
struct LiveGnosticClientTransportMappingTests {
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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
        let mapped = LiveGnosticClientTransport.map(
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

    @Test("A Runtime instance maps onto the Ascendant UI model, as a live Node advertises it")
    func mapsRuntimeInstance() {
        let objectID = UUID()
        let nodeID = UUID()
        // Shape recorded from `gnostic serve` at the pinned commit (issue #38).
        let mapped = LiveGnosticClientTransport.map(
            entry(
                objectType: GnosticObjectType.runtimeInstance,
                objectID: objectID,
                name: "gnostic-pk-runtime",
                knownProperties: [
                    "protocolMajor": .integer(3),
                    "runtimeID": .string(objectID.uuidString),
                    "nodeID": .string(nodeID.uuidString),
                    "runtimeKind": .string("local-command"),
                    "runtimeVersion": .string("0.5.0"),
                    "launchFingerprint": .string("01dc4f88"),
                    "health": .string("healthy"),
                    "rawCapabilities": .object(["session": .object([:])]),
                ]
            )
        )

        guard case let .ascendant(ascendant) = mapped else {
            Issue.record("expected an ascendant, got \(String(describing: mapped))")
            return
        }
        #expect(ascendant.key == NetworkObjectKey(objectID: objectID, providerID: providerID))
        #expect(ascendant.name == "gnostic-pk-runtime")
        #expect(ascendant.summary.isEmpty)
        // ACP capabilities are a nested object, not the retired Gnostic capability list.
        #expect(ascendant.capabilities.isEmpty)
        #expect(ascendant.backendHealth == .healthy)
        #expect(ascendant.backendKind == "local-command")
        #expect(ascendant.backendVersion == "0.5.0")
        #expect(ascendant.provenance.nodeID == nodeID)
        #expect(ascendant.compatibility.isCompatible)
    }

    @Test("A Timeline's attachedAscendantID finds the Runtime instance that operates it")
    func timelineFindsItsRuntimeInstance() throws {
        let runtimeID = UUID()
        let runtime = try #require(LiveGnosticClientTransport.map(
            entry(objectType: GnosticObjectType.runtimeInstance, objectID: runtimeID, name: "runtime")
        ))
        let timeline = try #require(LiveGnosticClientTransport.map(
            entry(
                objectType: GnosticObjectType.timeline,
                name: "Default Timeline",
                knownProperties: ["attachedAscendantID": .string(runtimeID.uuidString)]
            )
        ))
        var catalog = NetworkCatalogState()
        catalog.apply(.discovered(runtime))
        catalog.apply(.discovered(timeline))

        let listed = try #require(catalog.sortedTimelines.first)
        #expect(catalog.ascendant(for: listed)?.key.objectID == runtimeID)
    }

    @Test("The module's supported major is the pinned Gnostic's, and it is major 3")
    func supportedMajorMatchesGnostic() {
        #expect(NetworkCompatibility.supportedProtocolMajor == GnosticProtocol.currentMajor)
        #expect(NetworkCompatibility.supportedProtocolMajor == 3)
    }

    @Test("A protocol major 3 advertisement is compatible")
    func acceptsMajorThree() {
        let mapped = LiveGnosticClientTransport.map(
            entry(objectType: GnosticObjectType.timeline, name: "Current", protocolMajor: 3)
        )

        guard case let .timeline(timeline) = mapped else {
            Issue.record("expected a timeline, got \(String(describing: mapped))")
            return
        }
        #expect(timeline.compatibility.protocolMajor == 3)
        #expect(timeline.compatibility.isCompatible)
        #expect(NetworkEntityStatus.of(timeline, isOffline: false) == .live)
    }

    @Test("An older peer is retained and displays as incompatible with a reason")
    func olderPeerIsIncompatibleWithReason() {
        // No explicit flag: the compatibility decision is Gnostic's, from the major alone.
        let mapped = LiveGnosticClientTransport.map(
            entry(objectType: GnosticObjectType.timeline, name: "Older", protocolMajor: 2)
        )

        guard case let .timeline(timeline) = mapped else {
            Issue.record("expected a timeline, got \(String(describing: mapped))")
            return
        }
        #expect(!timeline.compatibility.isCompatible)
        let status = NetworkEntityStatus.of(timeline, isOffline: false)
        #expect(status == .incompatible(protocolMajor: 2))
        #expect(status.explanation?.contains("older") == true)
        #expect(NetworkChatAvailability.resolve(connection: .online, status: status, isArchived: false).reason == status.explanation)
    }

    @Test("Workspace tools and unrecognized types are skipped, never crashed on")
    func skipsUnlistedTypes() {
        #expect(LiveGnosticClientTransport.map(entry(objectType: GnosticObjectType.workspaceTool)) == nil)
        #expect(LiveGnosticClientTransport.map(entry(objectType: "me.atkn.gnostic.SomethingNew")) == nil)
        #expect(LiveGnosticClientTransport.map(entry(objectType: "")) == nil)
    }

    // MARK: - Turn updates (issue #10)

    @Test("Assistant text and snapshots map to their module-local cases")
    func mapsAssistantTextUpdates() {
        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 1,
            kind: .assistantText,
            text: "Hel"
        )) == [.textDelta("Hel")])

        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 2,
            kind: .assistantTextSnapshot,
            text: "Hello"
        )) == [.textSnapshot("Hello")])
    }

    @Test("Tool states map into module-local tool states with typed status")
    func mapsToolStates() {
        let update = AscendantTurnUpdate(
            sequence: 3,
            kind: .toolState,
            toolStates: [
                AscendantToolState(toolCallID: "call-1", title: "Shell", status: "in_progress", content: nil),
                AscendantToolState(toolCallID: "call-2", title: "Read", status: "completed", content: "done"),
            ]
        )
        #expect(LiveGnosticClientTransport.map(update) == [
            .toolState(GnosticTurnToolState(toolCallID: "call-1", title: "Shell", status: .inProgress)),
            .toolState(GnosticTurnToolState(toolCallID: "call-2", title: "Read", status: .completed, content: "done")),
        ])
    }

    @Test("Permission states map into module-local permission requests")
    func mapsPermissionStates() {
        let update = AscendantTurnUpdate(
            sequence: 4,
            kind: .permissionState,
            permissionStates: [
                AscendantPermissionState(
                    correlationID: "corr-1",
                    toolCallID: "call-1",
                    title: "Write a file",
                    status: "pending"
                ),
            ]
        )
        #expect(LiveGnosticClientTransport.map(update) == [
            .permission(GnosticTurnPermissionRequest(
                correlationID: "corr-1",
                toolCallID: "call-1",
                title: "Write a file",
                status: .pending
            )),
        ])
    }

    @Test("Terminal updates map to completed, cancelled, and failed")
    func mapsTerminalUpdates() {
        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 5,
            kind: .completion,
            terminal: true
        )) == [.completed])

        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 6,
            kind: .cancellation,
            terminal: true
        )) == [.cancelled])

        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 7,
            kind: .error,
            text: "The backend vanished.",
            terminal: true,
            reasonCode: "backendUnavailable",
            retryable: true
        )) == [.failed(message: "The backend vanished.", retryable: true)])

        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 8,
            kind: .error,
            terminal: true,
            reasonCode: "capacityExceeded",
            retryable: false
        )) == [.failed(message: "capacityExceeded", retryable: false)])
    }

    @Test("An unknown update kind is ignored")
    func ignoresUnknownTurnUpdateKind() {
        #expect(LiveGnosticClientTransport.map(AscendantTurnUpdate(
            sequence: 9,
            kind: "me.atkn.gnostic.something.new",
            terminal: false
        )).isEmpty)
    }

    // MARK: - Workspace attachment (issue #12)

    @Test("Attachment statuses map into the module-local refusal vocabulary")
    func mapsWorkspaceAttachmentStatus() {
        #expect(LiveGnosticClientTransport.map(WorkspaceAttachmentStatus.available(
            providerID: "provider.one",
            uri: "file:///workspace"
        )) == .available(providerID: "provider.one", uri: "file:///workspace"))
        #expect(LiveGnosticClientTransport.map(WorkspaceAttachmentStatus.unavailable) == .unavailable)
        #expect(LiveGnosticClientTransport.map(WorkspaceAttachmentStatus.malformed) == .malformed)
        #expect(LiveGnosticClientTransport.map(WorkspaceAttachmentStatus.ambiguous) == .ambiguous)
        #expect(LiveGnosticClientTransport.map(WorkspaceAttachmentStatus.unsupported) == .unsupported)
    }

    @Test("Effective statuses map, failing closed for unknown values")
    func mapsWorkspaceEffectiveStatus() {
        #expect(LiveGnosticClientTransport.map(GnosticWorkspaceEffectiveStatus.available) == .available)
        #expect(LiveGnosticClientTransport.map(GnosticWorkspaceEffectiveStatus.unavailable) == .unavailable)
        #expect(LiveGnosticClientTransport.map(GnosticWorkspaceEffectiveStatus.unsupported) == .unsupported)
    }

    @Test("An unapproved attach is refused before any connection is touched")
    func unapprovedAttachRefused() async throws {
        let transport = LiveGnosticClientTransport()

        await #expect(throws: GnosticTransportError.workspaceApprovalRequired) {
            try await transport.attachWorkspace(workspaceID: UUID(), to: UUID(), approved: false)
        }
    }
}
