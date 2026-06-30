import Foundation
import PKShared
import Testing
@testable import YakamozCore

/// Minimal permissioned tool used to exercise `MainActorToolApprover` without standing up a real
/// filesystem/terminal tool.
private struct StubPermissionedTool: PKShared.Tool, @unchecked Sendable {
    let id: String
    let name: String
    let description = "stub"
    let requiresPermission = true
    var parametersSchema: [String: AnyCodable] {
        [:]
    }

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: Any]) async throws -> ToolResult {
        .success("ok")
    }
}

struct ToolApprovalTests {
    @MainActor
    @Test("Enqueuing exposes a pending approval and approving completes the call with .approve")
    func approvingCompletesCall() async {
        let approver = MainActorToolApprover()
        let tool = AnyTool(StubPermissionedTool(id: "read_file", name: "Read File"))

        let child = Task {
            await approver.requestApproval(tool: tool, arguments: ["path": AnyCodable("/tmp/x")])
        }

        var item: PendingToolApproval?
        for _ in 0 ..< 1000 {
            if let first = approver.pending.first { item = first; break }
            await Task.yield()
        }
        guard let item else {
            #expect(Bool(false), "expected a pending approval to appear")
            child.cancel()
            return
        }

        #expect(item.toolId == "read_file")
        #expect(item.toolName == "Read File")
        #expect(item.argumentSummary.contains("path=/tmp/x"))

        approver.approve(item)

        let decision = await child.value
        #expect(decision == .approve)
        #expect(approver.pending.isEmpty)
    }

    @MainActor
    @Test("Denying a pending approval rejects the call with .deny")
    func denyingRejectsCall() async {
        let approver = MainActorToolApprover()
        let tool = AnyTool(StubPermissionedTool(id: "grep", name: "grep"))

        let child = Task {
            await approver.requestApproval(tool: tool, arguments: [:])
        }

        var item: PendingToolApproval?
        for _ in 0 ..< 1000 {
            if let first = approver.pending.first { item = first; break }
            await Task.yield()
        }
        guard let item else {
            #expect(Bool(false), "expected a pending approval to appear")
            child.cancel()
            return
        }

        approver.deny(item)

        let decision = await child.value
        #expect(decision == .deny)
        #expect(approver.pending.isEmpty)
    }

    @MainActor
    @Test("A self-gated tool (terminal_run) is auto-approved without enqueuing a prompt")
    func selfGatedToolAutoApproves() async {
        let approver = MainActorToolApprover()
        let tool = AnyTool(StubPermissionedTool(id: "terminal_run", name: "Terminal Run"))

        let decision = await approver.requestApproval(tool: tool, arguments: ["command": AnyCodable("ls")])

        #expect(decision == .approve)
        #expect(approver.pending.isEmpty)
    }
}
