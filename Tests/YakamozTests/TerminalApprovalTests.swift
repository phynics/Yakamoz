import Foundation
import Testing
@testable import YakamozCore

struct TerminalApprovalTests {
    @Test func denyAllApproverDenies() async {
        let decision = await DenyAllApprover().requestApproval(command: "rm -rf /", workspaceId: UUID())
        #expect(decision == .deny)
    }
}
