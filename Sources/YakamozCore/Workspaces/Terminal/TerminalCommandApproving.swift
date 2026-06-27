import Foundation

/// The user's decision when asked to approve a terminal command.
public enum TerminalApprovalDecision: Sendable {
    case approve
    case deny
    case allowForSession
}

/// Gate consulted before a terminal command runs. Implementations present the command to the
/// user (or apply a policy) and return the decision. Only `terminal_run` consults this; the
/// interaction tools (`terminal_send_input`/`terminal_interrupt`) steer an already-approved,
/// already-running command and do not re-prompt.
public protocol TerminalCommandApproving: Sendable {
    func requestApproval(command: String, workspaceId: UUID) async -> TerminalApprovalDecision
}

/// Default approver used when none is injected: denies every command, so the terminal backend
/// is never an un-gated arbitrary-exec primitive even when misconfigured (default-deny).
public struct DenyAllApprover: TerminalCommandApproving {
    public init() {}
    public func requestApproval(command _: String, workspaceId _: UUID) async -> TerminalApprovalDecision {
        .deny
    }
}
