import Foundation
import SwiftData
import Testing
@testable import YakamozCore

struct WorkspaceResolutionHelperTests {
    @Test func emptyWhenNothingAttached() {
        let c = ConversationModel(title: "t")
        let workspaces = [WorkspaceModel(displayName: "a", folderPath: "/a"), WorkspaceModel(displayName: "b", folderPath: "/b")]
        let resolved = WorkspaceResolutionHelper.attachedWorkspaces(for: c, in: workspaces)
        #expect(resolved.isEmpty)
    }

    @Test func preservesAttachmentOrder() {
        let c = ConversationModel(title: "t")
        let w1 = WorkspaceModel(displayName: "a", folderPath: "/a")
        let w2 = WorkspaceModel(displayName: "b", folderPath: "/b")
        c.attachedWorkspaceIds = [w2.id, w1.id]

        let resolved = WorkspaceResolutionHelper.attachedWorkspaces(for: c, in: [w1, w2])
        #expect(resolved.map(\.id) == [w2.id, w1.id])
    }

    @Test func missingIdsAreFilteredOut() {
        let c = ConversationModel(title: "t")
        let present = WorkspaceModel(displayName: "present", folderPath: "/present")
        let missingId = UUID()
        c.attachedWorkspaceIds = [present.id, missingId]

        let resolved = WorkspaceResolutionHelper.attachedWorkspaces(for: c, in: [present])
        #expect(resolved.map(\.id) == [present.id])
    }

}
