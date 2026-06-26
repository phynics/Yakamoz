import Foundation
import SwiftData
import Testing
import YakamozCore

final class ChatViewWorkspaceResolutionTests {
    @Test func attachedWorkspacesReturnsEmptyWhenNoWorkspacesAttached() {
        let conversation = ConversationModel(title: "Test")
        let allWorkspaces: [WorkspaceModel] = []

        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        #expect(attached.isEmpty)
    }

    @Test func attachedWorkspacesReturnsEmptyWhenConversationHasNoAttachments() {
        let conversation = ConversationModel(title: "Test")
        let workspace = WorkspaceModel(displayName: "Test", folderPath: "/test")
        let allWorkspaces = [workspace]

        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        #expect(attached.isEmpty)
    }

    @Test func attachedWorkspacesReturnsWorkspacesInAttachedIdOrder() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let conversation = ConversationModel(title: "Test", attachedWorkspaceIds: [id2, id1, id3])

        let workspace1 = WorkspaceModel(displayName: "WS1", folderPath: "/ws1")
        workspace1.id = id1
        let workspace2 = WorkspaceModel(displayName: "WS2", folderPath: "/ws2")
        workspace2.id = id2
        let workspace3 = WorkspaceModel(displayName: "WS3", folderPath: "/ws3")
        workspace3.id = id3

        let allWorkspaces = [workspace1, workspace2, workspace3]

        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        #expect(attached.count == 3)
        #expect(attached[0].id == id2)
        #expect(attached[1].id == id1)
        #expect(attached[2].id == id3)
    }

    @Test func attachedWorkspacesIncludesLegacySingleAttachFirst() {
        let legacyId = UUID()
        let newId = UUID()

        let conversation = ConversationModel(
            title: "Test",
            workspaceId: legacyId,
            attachedWorkspaceIds: [newId]
        )

        let legacyWorkspace = WorkspaceModel(displayName: "Legacy", folderPath: "/legacy")
        legacyWorkspace.id = legacyId
        let newWorkspace = WorkspaceModel(displayName: "New", folderPath: "/new")
        newWorkspace.id = newId

        let allWorkspaces = [legacyWorkspace, newWorkspace]

        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        #expect(attached.count == 2)
        #expect(attached[0].id == legacyId)
        #expect(attached[1].id == newId)
    }

    @Test func attachedWorkspacesIgnoresMissingWorkspaces() {
        let id1 = UUID()
        let id2 = UUID()
        let missingId = UUID()

        let conversation = ConversationModel(title: "Test", attachedWorkspaceIds: [id1, missingId, id2])

        let workspace1 = WorkspaceModel(displayName: "WS1", folderPath: "/ws1")
        workspace1.id = id1
        let workspace2 = WorkspaceModel(displayName: "WS2", folderPath: "/ws2")
        workspace2.id = id2

        let allWorkspaces = [workspace1, workspace2]

        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        #expect(attached.count == 2)
        #expect(attached[0].id == id1)
        #expect(attached[1].id == id2)
    }
}
