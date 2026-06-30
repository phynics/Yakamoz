import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("TerminalWorkspace")
struct TerminalWorkspaceTests {
    @Test("listTools returns the six terminal tool ids (including read_output from YAK-T6)")
    func listToolsReturnsFiveIds() async throws {
        let registry = TerminalSessionRegistry()
        let approver = MockApprover(decision: .deny)
        let workspace = TerminalWorkspace(rootURL: URL(fileURLWithPath: "/tmp"), registry: registry, approver: approver)

        let tools = try await workspace.listTools()
        let ids = tools.map { tool -> String in
            switch tool {
            case let .known(id):
                id
            default:
                ""
            }
        }

        #expect(Set(ids) == Set(["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait", "terminal_read_output"]))
        await registry.terminateAll()
    }

    @Test("reference reports attached, full-trust, rooted at the terminal's path")
    func referenceShape() async {
        let registry = TerminalSessionRegistry()
        let approver = MockApprover(decision: .deny)
        let rootURL = URL(fileURLWithPath: "/tmp")
        let workspace = TerminalWorkspace(rootURL: rootURL, registry: registry, approver: approver)

        let reference = workspace.reference

        #expect(reference.location == .attached)
        #expect(reference.rootPath == rootURL.path)
        #expect(reference.trustLevel == .full)
        await registry.terminateAll()
    }

    @Test("readFile is not supported on a terminal workspace")
    func readFileThrowsToolExecutionNotSupported() async throws {
        let registry = TerminalSessionRegistry()
        let approver = MockApprover(decision: .deny)
        let workspace = TerminalWorkspace(rootURL: URL(fileURLWithPath: "/tmp"), registry: registry, approver: approver)

        await #expect(throws: WorkspaceError.toolExecutionNotSupported) {
            try await workspace.readFile(path: "anything.txt")
        }
        await registry.terminateAll()
    }

    @Test("executeTool routes terminal_run through to a real session")
    func executeToolRoutesTerminalRun() async throws {
        let registry = TerminalSessionRegistry()
        let approver = MockApprover(decision: .approve)
        let workspace = TerminalWorkspace(rootURL: URL(fileURLWithPath: "/tmp"), registry: registry, approver: approver)

        let result = try await workspace.executeTool(id: "terminal_run", parameters: ["command": AnyCodable("echo hi")])

        #expect(result.success)
        #expect(result.output.contains("hi"))
        await registry.terminateAll()
    }
}
