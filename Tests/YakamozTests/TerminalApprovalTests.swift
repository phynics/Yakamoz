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

    @MainActor
    @Test func pendingApprovalForWorkspaceIDsIgnoresOtherConversations() async {
        let approver = MainActorApprover()
        let workspaceA = UUID()
        let workspaceB = UUID()

        let childA = Task {
            await approver.requestApproval(command: "echo from-a", workspaceId: workspaceA)
        }
        let childB = Task {
            await approver.requestApproval(command: "echo from-b", workspaceId: workspaceB)
        }

        for _ in 0 ..< 1000 {
            if approver.pending.count == 2 { break }
            await Task.yield()
        }

        #expect(approver.pending.count == 2)
        let pending = approver.pendingApproval(for: [workspaceA])
        #expect(pending?.workspaceId == workspaceA)
        #expect(pending?.command == "echo from-a")

        guard let pending else {
            childA.cancel()
            childB.cancel()
            return
        }

        approver.resolve(pending, with: .approve)
        #expect(approver.pending.count == 1)
        #expect(approver.pending.first?.workspaceId == workspaceB)

        approver.resolve(approver.pending[0], with: .deny)
        let decisionA = await childA.value
        let decisionB = await childB.value
        #expect(decisionA == .approve)
        #expect(decisionB == .deny)
    }
}
