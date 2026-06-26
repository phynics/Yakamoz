import Foundation
import Testing
import YakamozCore

final class ConversationAttachmentTests {
    @Test func legacyIdAlreadyInArrayIsNotDuplicated() {
        let c = ConversationModel(title: "t")
        let shared = UUID()
        c.workspaceId = shared
        c.attachedWorkspaceIds = [shared, UUID()]
        #expect(c.allAttachedWorkspaceIds.filter { $0 == shared }.count == 1)
    }
}
