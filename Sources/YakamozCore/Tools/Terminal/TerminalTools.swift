import Foundation
import JSONSchemaBuilder
import Logging
import PKShared

// MARK: - Truncation and rendering (YAK-T6)

/// Defines which slice(s) of output to inline when truncating.
public enum OutputShowMode: String, Sendable {
    case head // Only first slice
    case tail // Only last slice
    case both // First and last slices, with middle elided
}

/// Renders output with truncation if needed, returning the bounded slice and a truncation
/// notice with command id and counts.
///
/// - Parameters:
///   - fullOutput: The complete command output.
///   - commandId: The UUID of the command (used in the truncation notice).
///   - lineThreshold: Maximum lines to inline before truncating. Defaults to 200.
///   - byteThreshold: Maximum bytes to inline before truncating. Defaults to 16 KB.
///   - mode: Which slice(s) to show when truncating. Defaults to `.both`.
///   - showFull: If true, returns fullOutput intact even if over threshold (but still stores).
/// - Returns: (displayOutput, truncationNotice)
private func truncateOutput(
    fullOutput: String,
    commandId: UUID,
    lineThreshold: Int = 200,
    byteThreshold: Int = 16 * 1024,
    mode: OutputShowMode = .both,
    showFull: Bool = false
) -> (display: String, notice: String) {
    let lines = fullOutput.isEmpty ? [] : fullOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let byteCount = fullOutput.utf8.count

    // If full_output was requested or we're under both thresholds, return whole output.
    if showFull || (lines.count <= lineThreshold && byteCount <= byteThreshold) {
        return (fullOutput, "")
    }

    // Compute how many lines/bytes to show in each slice.
    let totalLines = lines.count
    let headCount = max(1, lineThreshold / 3) // roughly 1/3 of budget for head
    let tailCount = max(1, lineThreshold / 3) // roughly 1/3 for tail

    var displayLines: [String] = []
    var displayedBytes = 0

    switch mode {
    case .head:
        displayLines = Array(lines.prefix(min(headCount, totalLines)))
    case .tail:
        displayLines = Array(lines.suffix(min(tailCount, totalLines)))
    case .both:
        let firstLines = Array(lines.prefix(min(headCount, totalLines)))
        let lastLines = Array(lines.suffix(min(tailCount, totalLines)))
        displayLines = firstLines + lastLines
    }

    let displayOutput = displayLines.joined(separator: "\n")
    displayedBytes = displayOutput.utf8.count

    let notice = """

    [Output truncated — \(displayedBytes) of \(byteCount) bytes (\(lines.count) of \(totalLines) lines shown). Call tool `terminal_read_output` with command_id "\(commandId.uuidString)" to fetch the full output (supports offset/limit paging).]
    """

    return (displayOutput, notice)
}

/// Renders a `RunResult` into agent-facing text: status tag (`[exit N]` / `[running]`)
/// followed by the captured (possibly truncated) output, so the LLM can tell at a glance
/// whether the command completed and what its exit code was.
func renderRun(
    _ result: RunResult,
    showFull: Bool = false,
    showMode: OutputShowMode = .both
) -> String {
    switch result {
    case let .finished(output, code, commandId):
        let (display, notice) = truncateOutput(
            fullOutput: output,
            commandId: commandId,
            mode: showMode,
            showFull: showFull
        )
        return "[exit \(code)]\n\(display)\(notice)"
    case let .running(output, commandId):
        let (display, notice) = truncateOutput(
            fullOutput: output,
            commandId: commandId,
            mode: showMode,
            showFull: showFull
        )
        return "[running]\n\(display)\(notice)"
    }
}

/// Renders a `ReadResult` into agent-facing text, mirroring `renderRun`'s status-tag
/// convention so `terminal_read`/`terminal_wait` results look consistent with `terminal_run`.
func renderRead(
    _ result: ReadResult,
    showFull: Bool = false,
    showMode: OutputShowMode = .both
) -> String {
    let (display, notice) = truncateOutput(
        fullOutput: result.output,
        commandId: result.commandId,
        mode: showMode,
        showFull: showFull
    )
    switch result.status {
    case let .finished(code):
        return "[exit \(code)]\n\(display)\(notice)"
    case .running:
        return "[running]\n\(display)\(notice)"
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
            JSONProperty(key: "full_output") {
                JSONBoolean().description("If true, do not truncate output even if over threshold. Defaults to false.")
            }
            JSONProperty(key: "show") {
                JSONString()
                    .description("Which output slice(s) to show when truncated: 'head' (first), 'tail' (last), or 'both' (first+last with middle elided). Defaults to 'both'.")
                    .enumValues {
                        "head"
                        "tail"
                        "both"
                    }
            }
            JSONProperty(key: "grep") {
                JSONString().description("Optional regex pattern to filter output to matching lines before truncation.")
            }
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

        let fullOutput = params.optional("full_output", as: Bool.self) ?? false
        let showRaw = params.optional("show", as: String.self) ?? "both"
        let showMode = OutputShowMode(rawValue: showRaw) ?? .both
        let grepPattern = params.optional("grep", as: String.self)

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
        let result = try await session.run(command, graceMs: 4000, grepPattern: grepPattern)
        return .success(renderRun(result, showFull: fullOutput, showMode: showMode))
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

/// Reads the full stored output of a previously-run command by its UUID.
/// Does not require approval since it only reads output of an already-approved command.
public struct TerminalReadOutputTool: Tool, Sendable {
    public let id = "terminal_read_output"
    public let name = "Read Full Terminal Output"
    public let description = "Reads the full stored output of a previously-run terminal command, supporting pagination via offset and limit."
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
        {"name": "terminal_read_output", "arguments": {"command_id": "a1b2c3d4-5e6f-4a5b-8c9d-0e1f2a3b4c5d"}}
        </tool_call>
        """
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "command_id") {
                JSONString().description("The UUID of the command whose output to fetch.")
            }
            .required()
            JSONProperty(key: "offset") {
                JSONInteger().description("Starting line index (0-indexed). Defaults to 0.")
            }
            JSONProperty(key: "limit") {
                JSONInteger().description("Maximum lines to return. Defaults to nil (all remaining lines).")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let commandIdStr: String
        do {
            commandIdStr = try params.require("command_id", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let commandId = UUID(uuidString: commandIdStr) else {
            return .failure("Invalid command_id UUID format.")
        }

        let offset = params.optional("offset", as: Int.self) ?? 0
        let limit = params.optional("limit", as: Int.self)

        let session = try await registry.session(for: workspaceId, rootURL: rootURL)
        do {
            let (lines, totalLines, totalBytes) = try await session.readStoredOutput(
                commandId: commandId,
                offset: offset,
                limit: limit
            )
            let output = lines.joined(separator: "\n")
            let info = "[\(lines.count) of \(totalLines) lines shown; \(totalBytes) bytes total]"
            return .success("\(output)\n\(info)")
        } catch let error as TerminalWorkspaceError {
            return .failure(error.userFriendlyMessage)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
