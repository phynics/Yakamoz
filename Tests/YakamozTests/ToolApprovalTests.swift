import Foundation
import JSONSchema
import PKContracts
import Testing
@testable import YakamozCore

/// Minimal permissioned tool used to exercise `MainActorToolApprover` without standing up a real
/// filesystem/terminal tool.
private struct StubPermissionedTool: PKTool, @unchecked Sendable {
    let callName: String
    let name: String
    let toolDescription = "stub"
    let requiresPermission = true
    var parametersSchema: JSONSchema.Schema {
        Schema([:])
    }

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}

struct ToolApprovalTests {
    @MainActor
    @Test("Enqueuing exposes a pending approval and approving completes the call with .approve")
    func approvingCompletesCall() async {
        let approver = MainActorToolApprover()
        let tool = AnyTool(StubPermissionedTool(callName: "read_file", name: "Read File"))

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
        let tool = AnyTool(StubPermissionedTool(callName: "grep", name: "grep"))

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
        let tool = AnyTool(StubPermissionedTool(callName: "terminal_run", name: "Terminal Run"))

        let decision = await approver.requestApproval(tool: tool, arguments: ["command": AnyCodable("ls")])

        #expect(decision == .approve)
        #expect(approver.pending.isEmpty)
    }

    @MainActor
    @Test("An external approval (remote permission request) enqueues and resolves like a local one")
    func externalApprovalEnqueues() async {
        let approver = MainActorToolApprover()

        let child = Task {
            await approver.requestExternalApproval(
                toolId: "call-1",
                toolName: "Write a file",
                argumentSummary: "Write a file"
            )
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

        #expect(item.toolId == "call-1")
        #expect(item.toolName == "Write a file")

        approver.approve(item)

        let decision = await child.value
        #expect(decision == .approve)
        #expect(approver.pending.isEmpty)
    }
}
