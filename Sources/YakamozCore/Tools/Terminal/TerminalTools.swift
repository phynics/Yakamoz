import Foundation
import JSONSchemaBuilder
import Logging
import PKShared

/// Renders a `RunResult` into agent-facing text: status tag (`[exit N]` / `[running]`)
/// followed by the captured output, so the LLM can tell at a glance whether the command
/// completed and what its exit code was.
func renderRun(_ result: RunResult) -> String {
    switch result {
    case let .finished(output, code):
        return "[exit \(code)]\n\(output)"
    case let .running(output):
        return "[running]\n\(output)"
    }
}

/// Renders a `ReadResult` into agent-facing text, mirroring `renderRun`'s status-tag
/// convention so `terminal_read`/`terminal_wait` results look consistent with `terminal_run`.
func renderRead(_ result: ReadResult) -> String {
    switch result.status {
    case let .finished(code):
        return "[exit \(code)]\n\(result.output)"
    case .running:
        return "[running]\n\(result.output)"
    }
}

/// Runs a shell command in the workspace's terminal session, gated by `TerminalCommandApproving`
/// unless the session has already been marked allowed (via `.allowForSession`).
///
/// Only this tool consults the approver; `terminal_send_input`/`terminal_interrupt` steer an
/// already-approved, already-running command and do not re-prompt.
public struct TerminalRunTool: Tool, Sendable {
    public let id = "terminal_run"
    public let name = "Run Terminal Command"
    public let description = "Runs a shell command in the workspace's terminal session. Requires user approval unless the session was already allowed."
    public let requiresPermission = true

    public let workspaceId: UUID
    public let registry: TerminalSessionRegistry
    public let rootURL: URL
    public let approver: any TerminalCommandApproving

    public init(workspaceId: UUID, registry: TerminalSessionRegistry, rootURL: URL, approver: any TerminalCommandApproving) {
        self.workspaceId = workspaceId
        self.registry = registry
        self.rootURL = rootURL
        self.approver = approver
    }

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "terminal_run", "arguments": {"command": "ls -la"}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "command") {
                JSONString().description("The shell command to run.")
            }
            .required()
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let command: String
        do {
            command = try params.require("command", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        if await !registry.isAllowed(workspaceId) {
            switch await approver.requestApproval(command: command, workspaceId: workspaceId) {
            case .deny:
                return .failure("Command denied by user.")
            case .allowForSession:
                await registry.allowForSession(workspaceId)
            case .approve:
                break
            }
        }

        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        let result = try await session.run(command, graceMs: 4000)
        return .success(renderRun(result))
    }
}

/// Reads output accumulated since the last `read`/`wait`/`run` call on the workspace's
/// terminal session, without prompting for approval.
public struct TerminalReadTool: Tool, Sendable {
    public let id = "terminal_read"
    public let name = "Read Terminal Output"
    public let description = "Reads output accumulated since the last read/wait/run on the workspace's terminal session."
    public let requiresPermission = false

    public let workspaceId: UUID
    public let registry: TerminalSessionRegistry
    public let rootURL: URL

    public init(workspaceId: UUID, registry: TerminalSessionRegistry, rootURL: URL) {
        self.workspaceId = workspaceId
        self.registry = registry
        self.rootURL = rootURL
    }

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "terminal_read", "arguments": {}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {}.schema
    }

    public func execute(parameters _: [String: Any]) async throws -> ToolResult {
        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        let result = await session.read()
        return .success(renderRead(result))
    }
}

/// Waits (up to a timeout) for the workspace's terminal session's pending command to finish,
/// without prompting for approval.
public struct TerminalWaitTool: Tool, Sendable {
    public let id = "terminal_wait"
    public let name = "Wait For Terminal Command"
    public let description = "Waits up to a timeout for the workspace's terminal session's pending command to finish."
    public let requiresPermission = false

    public let workspaceId: UUID
    public let registry: TerminalSessionRegistry
    public let rootURL: URL

    public init(workspaceId: UUID, registry: TerminalSessionRegistry, rootURL: URL) {
        self.workspaceId = workspaceId
        self.registry = registry
        self.rootURL = rootURL
    }

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "terminal_wait", "arguments": {"timeout_ms": 5000}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "timeout_ms") {
                JSONInteger().description("Maximum time, in milliseconds, to wait for the pending command to finish. Defaults to 5000.")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let timeoutMs = params.optional("timeout_ms", as: Int.self) ?? 5000

        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        let result = await session.wait(timeoutMs: timeoutMs)
        return .success(renderRead(result))
    }
}

/// Sends text to the stdin of the workspace's terminal session's running command, without
/// prompting for approval (steering an already-approved, already-running command is part of
/// that command's existing approval).
public struct TerminalSendInputTool: Tool, Sendable {
    public let id = "terminal_send_input"
    public let name = "Send Terminal Input"
    public let description = "Sends text to the stdin of the workspace's terminal session's running command."
    public let requiresPermission = false

    public let workspaceId: UUID
    public let registry: TerminalSessionRegistry
    public let rootURL: URL

    public init(workspaceId: UUID, registry: TerminalSessionRegistry, rootURL: URL) {
        self.workspaceId = workspaceId
        self.registry = registry
        self.rootURL = rootURL
    }

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "terminal_send_input", "arguments": {"text": "y\\n"}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "text") {
                JSONString().description("The raw text to send to the running command's stdin, including any trailing newline it needs.")
            }
            .required()
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let text: String
        do {
            text = try params.require("text", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        do {
            try await session.sendInput(text)
        } catch let error as TerminalWorkspaceError {
            Log.terminal.warning("failed to send input to terminal", metadata: [
                "workspaceID": "\(workspaceId)",
            ])
            return .failure(error.userFriendlyMessage)
        } catch {
            Log.terminal.warning("unexpected error sending input to terminal", metadata: [
                "workspaceID": "\(workspaceId)",
            ])
            return .failure(error.localizedDescription)
        }
        return .success("input sent")
    }
}

/// Sends an interrupt (Ctrl-C) to the workspace's terminal session's running command, without
/// prompting for approval.
public struct TerminalInterruptTool: Tool, Sendable {
    public let id = "terminal_interrupt"
    public let name = "Interrupt Terminal Command"
    public let description = "Sends Ctrl-C to the workspace's terminal session's running command."
    public let requiresPermission = false

    public let workspaceId: UUID
    public let registry: TerminalSessionRegistry
    public let rootURL: URL

    public init(workspaceId: UUID, registry: TerminalSessionRegistry, rootURL: URL) {
        self.workspaceId = workspaceId
        self.registry = registry
        self.rootURL = rootURL
    }

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "terminal_interrupt", "arguments": {}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {}.schema
    }

    public func execute(parameters _: [String: Any]) async throws -> ToolResult {
        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        await session.interrupt()
        return .success("interrupt sent")
    }
}
