import Foundation
import PKShared

/// A single outstanding permissioned-tool approval request, surfaced to the UI for rendering.
///
/// Uses only `Foundation`/`String`/`UUID` so the app target can render it without naming any
/// `PKShared` type (the app links only `YakamozCore` — see `AppHealthStatus`).
public struct PendingToolApproval: Identifiable, Sendable {
    public let id: UUID
    /// The tool's stable id (e.g. `read_file`).
    public let toolId: String
    /// The tool's human-readable display name.
    public let toolName: String
    /// A compact, human-readable summary of the arguments the tool would run with.
    public let argumentSummary: String

    public init(id: UUID, toolId: String, toolName: String, argumentSummary: String) {
        self.id = id
        self.toolId = toolId
        self.toolName = toolName
        self.argumentSummary = argumentSummary
    }
}

/// App-layer concrete `ToolApprovalGate` that bridges PositronicKit's runtime approval gate to a
/// SwiftUI prompt — the tool-call analogue of `MainActorApprover` (which gates `terminal_run`).
///
/// `ToolRouter` calls `requestApproval(tool:arguments:)` off the main actor for every tool whose
/// `requiresPermission` is `true` (Yakamoz's filesystem tools: `read_file`, `ls`, `find`,
/// `search_files`, `grep`). This type hops to the main actor, appends a `PendingToolApproval` to
/// the observable `pending` list (which a banner renders), and parks a `CheckedContinuation`. The
/// agent stays blocked until the UI calls `approve`/`deny`, at which point the call proceeds or is
/// rejected with `ToolError.permissionDenied`.
///
/// Tools listed in `selfGatedToolIds` are approved here automatically because they already carry
/// their own upstream approval gate — `terminal_run` is gated by `TerminalCommandApproving` inside
/// the terminal tool, so re-prompting it through this gate would double-prompt the user.
@MainActor
@Observable
public final class MainActorToolApprover: ToolApprovalGate {
    public private(set) var pending: [PendingToolApproval] = []

    private var continuations: [UUID: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    private let selfGatedToolIds: Set<String>

    public init(selfGatedToolIds: Set<String> = ["terminal_run"]) {
        self.selfGatedToolIds = selfGatedToolIds
    }

    /// Called off the main actor by `ToolRouter`. Auto-approves self-gated tools; otherwise hops to
    /// the main actor to enqueue the request and suspends until `approve`/`deny` is called.
    public nonisolated func requestApproval(
        tool: AnyTool,
        arguments: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        if selfGatedToolIds.contains(tool.id) { return .approve }
        return await enqueue(
            toolId: tool.id,
            toolName: tool.name,
            argumentSummary: Self.summarize(arguments)
        )
    }

    /// The oldest pending approval, if any. The banner renders this.
    public var oldestPending: PendingToolApproval? {
        pending.first
    }

    /// Approves the pending request with the given id, resuming the waiting tool call so it executes.
    public func approve(_ id: UUID) {
        resolve(id, with: .approve)
    }

    /// Denies the pending request with the given id, resuming the waiting call so it is rejected.
    public func deny(_ id: UUID) {
        resolve(id, with: .deny)
    }

    /// Convenience overloads taking the `PendingToolApproval` value directly.
    public func approve(_ pendingApproval: PendingToolApproval) {
        approve(pendingApproval.id)
    }

    public func deny(_ pendingApproval: PendingToolApproval) {
        deny(pendingApproval.id)
    }

    private func enqueue(
        toolId: String,
        toolName: String,
        argumentSummary: String
    ) async -> ToolApprovalDecision {
        await withCheckedContinuation { continuation in
            let id = UUID()
            continuations[id] = continuation
            pending.append(PendingToolApproval(
                id: id,
                toolId: toolId,
                toolName: toolName,
                argumentSummary: argumentSummary
            ))
        }
    }

    private func resolve(_ id: UUID, with decision: ToolApprovalDecision) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: decision)
    }

    /// Renders a compact `key=value, …` summary of tool arguments (max 4 keys, values truncated),
    /// sorted by key for stable display.
    private static func summarize(_ arguments: [String: AnyCodable]) -> String {
        guard !arguments.isEmpty else { return "(no arguments)" }
        return arguments.keys.sorted().prefix(4).map { key in
            let value = String(describing: arguments[key]?.value ?? "").prefix(60)
            return "\(key)=\(value)"
        }.joined(separator: ", ")
    }
}
