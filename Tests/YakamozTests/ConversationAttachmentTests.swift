import Foundation
import SwiftData
import Testing
@testable import YakamozCore

struct ConversationAttachmentTests {
    @Test func legacyWorkspaceIdFoldsIntoAttachedList() throws {
        let c = ConversationModel(title: "t")
        c.workspaceId = UUID()
        // allAttachedWorkspaceIds merges legacy single id with the new array
        #expect(try c.allAttachedWorkspaceIds == [#require(c.workspaceId)])
    }

    @Test func newAttachmentsUseTheArray() {
        let c = ConversationModel(title: "t")
        let a = UUID(); let b = UUID()
        c.attachedWorkspaceIds = [a, b]
        #expect(Set(c.allAttachedWorkspaceIds) == [a, b])
    }

    @Test func backfillLegacyAttachment() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [UUID(), UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        // Legacy id should be moved to the array
        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.contains(legacyId))
        // Should not duplicate
        #expect(c.attachedWorkspaceIds.filter { $0 == legacyId }.count == 1)
    }

    @Test func backfillLegacyAttachmentIdempotent() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)
        let afterFirstCall = c.attachedWorkspaceIds.count

        // Call again when workspaceId is already nil
        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        // Should be no-op
        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.count == afterFirstCall)
    }

    @Test func backfillLegacyAttachmentWithAlreadyPresentId() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [legacyId, UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.filter { $0 == legacyId }.count == 1)
    }

    @Test func backfillLegacyAttachmentNoOpWhenNil() {
        let c = ConversationModel(title: "t")
        let otherId = UUID()
        c.workspaceId = nil
        c.attachedWorkspaceIds = [otherId]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds == [otherId])
    }
}
