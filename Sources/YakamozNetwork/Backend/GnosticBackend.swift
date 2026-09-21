import Foundation
import PKContracts
import YakamozCore

/// Runs remote Ascendant Turns through the shared `ChatRunning` seam, so
/// `ChatViewModel` (and the app's chat surface) drive a network Turn exactly like a
/// local one (issue #10).
///
/// The adapter maps the transport's module-local ``GnosticTurnEvent`` stream onto
/// PositronicKit `TurnEvent`s:
///
/// - assistant text (deltas and snapshots) becomes streamed `.generation` text,
/// - tool lifecycle updates become tool-execution traces,
/// - permission requests go through the same `MainActorToolApprover` banner as local
///   permissioned tools, and the decision is published back to the Ascendant,
/// - terminal failures become `.error` events, so the existing error row + retry
///   affordance works unchanged.
///
/// Network sessions have no prompt/turn telemetry upstream, so `inspectorAvailable`
/// is `false`; the app must not offer the turn-inspector tabs for them.
public struct GnosticBackend: ChatRunning, BackendInspectorProviding {
    public let inspectorAvailable = false

    private let transport: any GnosticClientTransport
    private let approver: MainActorToolApprover

    public init(transport: any GnosticClientTransport, approver: MainActorToolApprover) {
        self.transport = transport
        self.approver = approver
    }

    public func run(_ request: ChatRunRequest) async throws -> AsyncStream<TurnEvent> {
        let turnRequest = GnosticTurnRequest(
            timelineID: request.timelineID,
            clientTurnID: request.requestID.uuidString,
            message: request.message
        )
        let events = try await transport.runTurn(turnRequest)
        let pair = AsyncStream<TurnEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let task = Task {
            var textSoFar = ""
            for await event in events {
                switch event {
                case let .textDelta(delta):
                    textSoFar += delta
                    pair.continuation.yield(.generation(delta))

                case let .textSnapshot(snapshot):
                    // Emit only the suffix beyond what has already been streamed; a
                    // snapshot that diverged (server-side compaction) is adopted as the
                    // new baseline without replaying text the transcript already has.
                    if snapshot.hasPrefix(textSoFar) {
                        let suffix = String(snapshot.dropFirst(textSoFar.count))
                        if !suffix.isEmpty {
                            pair.continuation.yield(.generation(suffix))
                        }
                    } else if textSoFar.isEmpty, !snapshot.isEmpty {
                        pair.continuation.yield(.generation(snapshot))
                    }
                    textSoFar = snapshot

                case let .toolState(state):
                    if let mapped = Self.turnEvent(for: state) {
                        pair.continuation.yield(mapped)
                    }

                case let .permission(permission):
                    guard permission.status == .pending else { continue }
                    let decision = await approver.requestExternalApproval(
                        toolId: permission.toolCallID,
                        toolName: permission.title,
                        argumentSummary: permission.title
                    )
                    // A failed publish leaves the Ascendant waiting; the Turn's own
                    // terminal timeout then surfaces the failure on the update stream.
                    try? await transport.respondToPermission(
                        correlationID: permission.correlationID,
                        approved: decision == .approve,
                        request: turnRequest
                    )

                case .completed:
                    pair.continuation.finish()
                    return

                case .cancelled:
                    pair.continuation.yield(.generationCancelled())
                    pair.continuation.finish()
                    return

                case let .failed(message, _):
                    pair.continuation.yield(.error(.error(message: message, identity: nil)))
                    pair.continuation.finish()
                    return
                }
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    /// Projects one remote tool state onto the turn vocabulary `ChatEventReducer`
    /// already folds into tool traces.
    static func turnEvent(for state: GnosticTurnToolState) -> TurnEvent? {
        switch state.status {
        case .pending, .inProgress:
            return .delta(.toolExecution(
                toolCallID: state.toolCallID,
                status: .attempting(
                    name: state.title ?? state.toolCallID,
                    reference: .known(id: state.toolCallID)
                )
            ))
        case .completed:
            return .completion(.toolExecution(
                toolCallID: state.toolCallID,
                status: .success(ToolResult.success(state.content ?? ""))
            ))
        case .failed:
            return .delta(.toolExecution(
                toolCallID: state.toolCallID,
                status: .failed(
                    reference: .known(id: state.toolCallID),
                    error: state.content ?? "Tool failed."
                )
            ))
        case nil:
            return nil
        }
    }
}
