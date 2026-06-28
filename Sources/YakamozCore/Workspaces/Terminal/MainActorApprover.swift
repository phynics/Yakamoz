import Foundation

/// A single outstanding approval request, surfaced to the UI for rendering (Task 20's banner).
public struct PendingApproval: Identifiable, Sendable {
    public let id: UUID
    public let command: String
    public let workspaceId: UUID
}

/// App-layer concrete `TerminalCommandApproving` that bridges the terminal tools' async
/// approval requests to a SwiftUI prompt.
///
/// Each `terminal_run` call lands here off the main actor and suspends. This type hops to the
/// main actor, appends a `PendingApproval` to the observable `pending` list (which a SwiftUI
/// banner renders), and parks a `CheckedContinuation` keyed by the request's id. The agent
/// stays blocked until the UI calls `resolve(_:with:)` with the user's choice (approve / deny /
/// allow-for-session), at which point the continuation resumes and the tool call proceeds.
@MainActor
@Observable
public final class MainActorApprover: TerminalCommandApproving {
    public private(set) var pending: [PendingApproval] = []

    private var continuations: [UUID: CheckedContinuation<TerminalApprovalDecision, Never>] = [:]

    public init() {}

    /// Called off the main actor by the terminal tools. Hops to the main actor to enqueue the
    /// request and suspends until `resolve` is called with a decision.
    public nonisolated func requestApproval(command: String, workspaceId: UUID) async -> TerminalApprovalDecision {
        await enqueue(command: command, workspaceId: workspaceId)
    }

    /// Returns the oldest pending approval for one of the given workspaces.
    public func pendingApproval(for workspaceIDs: Set<UUID>) -> PendingApproval? {
        pending.first { workspaceIDs.contains($0.workspaceId) }
    }

    /// Appends the pending request and parks a continuation, entirely on the main actor so the
    /// mutation of `pending`/`continuations` is synchronous and free of cross-actor hazards.
    private func enqueue(command: String, workspaceId: UUID) async -> TerminalApprovalDecision {
        await withCheckedContinuation { continuation in
            let id = UUID()
            continuations[id] = continuation
            pending.append(PendingApproval(id: id, command: command, workspaceId: workspaceId))
        }
    }

    /// Resolves the pending request with the given id, removing it from `pending` and resuming
    /// the waiting tool call. No-op if the id is unknown (e.g. already resolved).
    public func resolve(_ id: UUID, with decision: TerminalApprovalDecision) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: decision)
    }

    /// Convenience overload taking the `PendingApproval` value directly.
    public func resolve(_ pendingApproval: PendingApproval, with decision: TerminalApprovalDecision) {
        resolve(pendingApproval.id, with: decision)
    }
}
