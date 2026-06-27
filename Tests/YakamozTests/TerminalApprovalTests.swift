import Foundation
import Testing
@testable import YakamozCore

struct TerminalApprovalTests {
    @Test func denyAllApproverDenies() async {
        let decision = await DenyAllApprover().requestApproval(command: "rm -rf /", workspaceId: UUID())
        #expect(decision == .deny)
    }

    @MainActor
    @Test func enqueuingExposesPendingAndResolvingCompletesTheCall() async {
        let approver = MainActorApprover()
        let workspaceId = UUID()

        let child = Task {
            await approver.requestApproval(command: "ls", workspaceId: workspaceId)
        }

        var item: PendingApproval?
        for _ in 0 ..< 1000 {
            if let first = approver.pending.first {
                item = first
                break
            }
            await Task.yield()
        }

        guard let item else {
            #expect(Bool(false), "expected a pending approval to appear")
            child.cancel()
            return
        }

        approver.resolve(item.id, with: .approve)

        let decision = await child.value
        #expect(decision == .approve)
        #expect(approver.pending.isEmpty)
    }

    @MainActor
    @Test func resolvingWithDenyReturnsDenyAndClearsPending() async {
        let approver = MainActorApprover()
        let workspaceId = UUID()

        let child = Task {
            await approver.requestApproval(command: "rm file.txt", workspaceId: workspaceId)
        }

        var item: PendingApproval?
        for _ in 0 ..< 1000 {
            if let first = approver.pending.first {
                item = first
                break
            }
            await Task.yield()
        }

        guard let item else {
            #expect(Bool(false), "expected a pending approval to appear")
            child.cancel()
            return
        }

        approver.resolve(item.id, with: .deny)

        let decision = await child.value
        #expect(decision == .deny)
        #expect(approver.pending.isEmpty)
    }
}
