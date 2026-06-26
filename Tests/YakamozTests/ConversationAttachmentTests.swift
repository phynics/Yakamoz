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
}
