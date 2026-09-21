import Foundation
import PKContracts
import YakamozCore

/// Failures raised when a Network Turn cannot represent a local chat request.
public enum GnosticBackendError: Error, Sendable, Equatable, LocalizedError {
    /// The request uses a local-only field that Gnostic cannot execute.
    case unsupportedRequestField(String)
    /// The backend must be scoped to the selected provider-scoped Timeline first.
    case timelineScopeRequired
    /// The view model addressed a different Timeline than the backend scope.
    case timelineMismatch(expected: UUID, actual: UUID)

    /// A user-facing explanation of why the Network Turn could not start or continue.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedRequestField(field):
            "Network Turns do not support the \(field) request option."
        case .timelineScopeRequired:
            "The Network Turn is missing its provider-scoped Timeline."
        case let .timelineMismatch(expected, actual):
            "The Network Turn addressed \(actual), but this backend is scoped to \(expected)."
        }
    }
}

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
    private let timelineKey: NetworkObjectKey?

    /// Creates a Network backend, optionally scoped to one provider-scoped Timeline.
    ///
    /// An unscoped value is useful as a factory for ``scoped(to:)`` but cannot run a
    /// Turn until it has a Timeline scope.
    ///
    /// - Parameters:
    ///   - transport: The Gnostic transport adapter.
    ///   - approver: The approval surface for remote tool permissions.
    ///   - timelineKey: The provider-scoped Timeline, when this value is used directly.
    public init(
        transport: any GnosticClientTransport,
        approver: MainActorToolApprover,
        timelineKey: NetworkObjectKey? = nil
    ) {
        self.transport = transport
        self.approver = approver
        self.timelineKey = timelineKey
    }

    /// Returns a Network backend scoped to one provider-scoped Timeline.
    public func scoped(to timelineKey: NetworkObjectKey) -> GnosticBackend {
        GnosticBackend(transport: transport, approver: approver, timelineKey: timelineKey)
    }

    public func run(_ request: ChatRunRequest) async throws -> AsyncStream<TurnEvent> {
        try Self.validate(request)
        guard let timelineKey else { throw GnosticBackendError.timelineScopeRequired }
        guard request.timelineID == timelineKey.objectID else {
            throw GnosticBackendError.timelineMismatch(
                expected: timelineKey.objectID,
                actual: request.timelineID
            )
        }
        let turnRequest = GnosticTurnRequest(
            timelineKey: timelineKey,
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
                    do {
                        try await transport.respondToPermission(
                            correlationID: permission.correlationID,
                            approved: decision == .approve,
                            request: turnRequest
                        )
                    } catch {
                        pair.continuation.yield(.error(
                            .error(message: Self.message(for: error), identity: nil)
                        ))
                        pair.continuation.finish()
                        // Releasing `events` on return triggers the transport stream's
                        // termination hook, which cancels the underlying remote Turn.
                        return
                    }

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
            pair.continuation.yield(.error(
                .error(
                    message: "The Network Turn ended before it completed.",
                    identity: nil
                )
            ))
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private static func validate(_ request: ChatRunRequest) throws {
        if !request.tools.isEmpty { throw GnosticBackendError.unsupportedRequestField("tools") }
        if request.systemInstructions != nil {
            throw GnosticBackendError.unsupportedRequestField("systemInstructions")
        }
        if request.maxModelRounds != 5 {
            throw GnosticBackendError.unsupportedRequestField("maxModelRounds")
        }
        if request.generationParameters != nil {
            throw GnosticBackendError.unsupportedRequestField("generationParameters")
        }
        if request.structuredOutput != nil {
            throw GnosticBackendError.unsupportedRequestField("structuredOutput")
        }
        if !request.sidecars.isEmpty {
            throw GnosticBackendError.unsupportedRequestField("sidecars")
        }
        if let toolOutputs = request.toolOutputs, !toolOutputs.isEmpty {
            throw GnosticBackendError.unsupportedRequestField("toolOutputs")
        }
    }

    private static func message(for error: Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
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
