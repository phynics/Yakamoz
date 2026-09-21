import Foundation
import Testing
@testable import YakamozNetwork

/// Issue #12: the app-facing workspace attach/detach state, driven offline by
/// ``FakeGnosticTransport``.
@Suite("NetworkWorkspaceController")
@MainActor
struct NetworkWorkspaceControllerTests {
    @Test("Refreshing statuses records attachment and effective status")
    func refreshRecordsStatuses() async {
        let transport = FakeGnosticTransport()
        let workspaceID = UUID()
        await transport.setAttachment(.available(providerID: "provider.one", uri: "file:///w"), for: workspaceID)
        await transport.setEffectiveStatus(.available, for: workspaceID)
        let controller = NetworkWorkspaceController(transport: transport)

        await controller.refreshStatuses(workspaceIDs: [workspaceID])

        #expect(controller.attachments[workspaceID] == .available(providerID: "provider.one", uri: "file:///w"))
        #expect(controller.effectiveStatuses[workspaceID] == .available)
        #expect(controller.canAttach(workspaceID: workspaceID))
        #expect(controller.refusalReason(workspaceID: workspaceID) == nil)
    }

    @Test("Only a uniquely advertised workspace is attachable")
    func ambiguousAndMalformedAreNotAttachable() async {
        let transport = FakeGnosticTransport()
        let ambiguous = UUID()
        let malformed = UUID()
        let unknown = UUID()
        await transport.setAttachment(.ambiguous, for: ambiguous)
        await transport.setAttachment(.malformed, for: malformed)
        let controller = NetworkWorkspaceController(transport: transport)

        await controller.refreshStatuses(workspaceIDs: [ambiguous, malformed])

        #expect(!controller.canAttach(workspaceID: ambiguous))
        #expect(!controller.canAttach(workspaceID: malformed))
        #expect(!controller.canAttach(workspaceID: unknown))
        #expect(controller.refusalReason(workspaceID: ambiguous) != nil)
        #expect(controller.refusalReason(workspaceID: malformed) != nil)
        #expect(controller.refusalReason(workspaceID: unknown) != nil)
    }

    @Test("An available advertisement with an unusable effective status is not attachable")
    func effectiveStatusGatesAttach() async {
        let transport = FakeGnosticTransport()
        let workspaceID = UUID()
        await transport.setAttachment(.available(providerID: "provider.one", uri: "file:///w"), for: workspaceID)
        await transport.setEffectiveStatus(.unsupported, for: workspaceID)
        let controller = NetworkWorkspaceController(transport: transport)

        await controller.refreshStatuses(workspaceIDs: [workspaceID])

        #expect(!controller.canAttach(workspaceID: workspaceID))
        #expect(controller.refusalReason(workspaceID: workspaceID)?.contains("unsupported") == true)
    }

    @Test("Attach forwards the user's approval and reports success")
    func attachForwardsApproval() async {
        let transport = FakeGnosticTransport()
        let workspaceID = UUID()
        let timelineID = UUID()
        let controller = NetworkWorkspaceController(transport: transport)

        let succeeded = await controller.attach(workspaceID: workspaceID, to: timelineID)

        #expect(succeeded)
        #expect(controller.errorMessage == nil)
        #expect(controller.isWorking == false)
        let requests = await transport.attachRequests
        #expect(requests == [FakeGnosticTransport.AttachRequest(
            workspaceID: workspaceID,
            timelineID: timelineID,
            approved: true
        )])
    }

    @Test("A failed attach surfaces a user-facing message and reports failure")
    func attachFailureSurfacesMessage() async {
        let transport = FakeGnosticTransport()
        await transport.failNextAttach(.workspaceUnavailable("the workspace vanished"))
        let controller = NetworkWorkspaceController(transport: transport)

        let succeeded = await controller.attach(workspaceID: UUID(), to: UUID())

        #expect(!succeeded)
        #expect(controller.errorMessage?.contains("the workspace vanished") == true)
        #expect(await transport.attachRequests.isEmpty)
    }

    @Test("Detach forwards and reports success")
    func detachForwards() async {
        let transport = FakeGnosticTransport()
        let workspaceID = UUID()
        let timelineID = UUID()
        let controller = NetworkWorkspaceController(transport: transport)

        let succeeded = await controller.detach(workspaceID: workspaceID, from: timelineID)

        #expect(succeeded)
        #expect(controller.errorMessage == nil)
        #expect(await transport.detachRequests == [FakeGnosticTransport.DetachRequest(
            workspaceID: workspaceID,
            timelineID: timelineID
        )])
    }

    @Test("A failed detach surfaces a user-facing message")
    func detachFailureSurfacesMessage() async {
        let transport = FakeGnosticTransport()
        await transport.failNextDetach(.workspaceUnavailable("detach rejected"))
        let controller = NetworkWorkspaceController(transport: transport)

        let succeeded = await controller.detach(workspaceID: UUID(), from: UUID())

        #expect(!succeeded)
        #expect(controller.errorMessage?.contains("detach rejected") == true)
    }
}
