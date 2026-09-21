import Foundation

/// A change pushed by a ``GnosticClientTransport`` as it observes the network.
///
/// This is the module-local seam event. Upstream `GnosticCore` catalog types are
/// mapped into ``DiscoveredNetworkObject`` inside `GnosticCoreTransport`, so no
/// GnosticCore symbol crosses this boundary.
public enum GnosticTransportEvent: Sendable, Equatable {
    /// A supported object was advertised or resolved.
    case discovered(DiscoveredNetworkObject)
    /// A previously listed object was deadvertised by its provider.
    case deadvertised(NetworkObjectKey)
    /// A provider published a lifecycle identity deadvertisement; every record
    /// owned by that provider was removed.
    case providerEvicted(providerID: String)
    /// The transport lost its broker connection.
    case connectionLost(reason: String)
}

/// A streamed step of one remote Turn, mapped from the Gnostic update vocabulary.
///
/// Module-local so the backend adapter can fold these into PositronicKit
/// ``TurnEvent``s without any GnosticCore symbol crossing the transport seam.
public enum GnosticTurnEvent: Sendable, Equatable {
    /// An assistant-text fragment to append.
    case textDelta(String)
    /// The Ascendant's full assistant text so far; consumers emit only the suffix
    /// beyond what they have already seen.
    case textSnapshot(String)
    /// A tool call's lifecycle state changed.
    case toolState(GnosticTurnToolState)
    /// The Ascendant asked for permission to run a tool.
    case permission(GnosticTurnPermissionRequest)
    /// The Turn finished successfully.
    case completed
    /// The Turn was cancelled at the Ascendant.
    case cancelled
    /// The Turn failed; `retryable` mirrors the Ascendant's own guidance.
    case failed(message: String, retryable: Bool)

    /// Whether this event ends the Turn's stream.
    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .textDelta, .textSnapshot, .toolState, .permission:
            false
        }
    }
}

/// One tool call's lifecycle state inside a remote Turn.
public struct GnosticTurnToolState: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    public let toolCallID: String
    public let title: String?
    public let status: Status?
    public let content: String?

    public init(toolCallID: String, title: String? = nil, status: Status? = nil, content: String? = nil) {
        self.toolCallID = toolCallID
        self.title = title
        self.status = status
        self.content = content
    }
}

/// A permission request the Ascendant is waiting on.
public struct GnosticTurnPermissionRequest: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case selected
        case denied
        case connectionLost = "connection_lost"
    }

    public let correlationID: String
    public let toolCallID: String
    public let title: String
    public let status: Status?

    public init(correlationID: String, toolCallID: String, title: String, status: Status?) {
        self.correlationID = correlationID
        self.toolCallID = toolCallID
        self.title = title
        self.status = status
    }
}

/// One identified remote Turn: the addressed Timeline plus the stable client-supplied
/// Turn identity that makes the Turn replayable.
public struct GnosticTurnRequest: Sendable, Equatable {
    public let timelineID: UUID
    public let clientTurnID: String
    public let message: String

    public init(timelineID: UUID, clientTurnID: String, message: String) {
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.message = message
    }
}

/// Whether a discovered Workspace can be attached without ambiguity.
///
/// Mirrors Gnostic's provider-independent attachment status. `.available` means the
/// Workspace is uniquely advertised and attachable; every other case is a refusal
/// reason the UI must not offer an attach action for.
public enum GnosticWorkspaceAttachment: Sendable, Equatable {
    case available(providerID: String, uri: String)
    case unavailable
    case malformed
    case ambiguous
    case unsupported

    /// Whether the attachment may be offered to the user.
    public var isAttachable: Bool {
        if case .available = self { return true }
        return false
    }

    /// A user-facing refusal reason, or `nil` when attachable.
    public var refusalReason: String? {
        switch self {
        case .available:
            nil
        case .unavailable:
            "This workspace is not available right now."
        case .malformed:
            "This workspace advertisement is malformed and cannot be attached."
        case .ambiguous:
            "More than one provider advertises this workspace; it cannot be attached."
        case .unsupported:
            "This workspace does not support attachment."
        }
    }
}

/// Gnostic's effective usability for a discovered Workspace.
public enum GnosticWorkspaceEffective: String, Sendable, Equatable {
    case available
    case unavailable
    case unsupported
}

/// Failures a transport can raise while connecting, discovering, or running turns.
public enum GnosticTransportError: Error, Sendable, Equatable, LocalizedError {
    /// A discover or turn request was issued before a successful connect.
    case notConnected
    /// The transport could not reach or start the broker session.
    case connectionFailed(String)
    /// A turn or permission response could not be addressed to a serving provider.
    case turnUnavailable(String)
    /// A Workspace operation failed (unresolvable, ambiguous, rejected, ...).
    case workspaceUnavailable(String)
    /// An attach was attempted without the user's explicit approval.
    case workspaceApprovalRequired

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The Gnostic transport is not connected."
        case let .connectionFailed(detail):
            "Could not connect to the Gnostic broker: \(detail)"
        case let .turnUnavailable(detail):
            "The network turn is unavailable: \(detail)"
        case let .workspaceUnavailable(detail):
            "The network workspace operation failed: \(detail)"
        case .workspaceApprovalRequired:
            "Attaching a network workspace requires your approval."
        }
    }
}

/// The connection/discovery seam between ``NetworkClientSession`` and a concrete
/// Gnostic client.
///
/// Production is ``GnosticCoreTransport``; tests use an offline fake. Keeping the
/// seam narrow means the connection lifecycle, backoff, and catalog reduction stay
/// pure and unit-testable with no broker in CI (issue #8).
public protocol GnosticClientTransport: Sendable {
    /// Establishes a broker session using `configuration`.
    ///
    /// - Throws: ``GnosticTransportError`` when the session cannot start.
    func connect(_ configuration: NetworkBrokerConfiguration) async throws

    /// Tears the session down. Safe to call when not connected.
    func disconnect() async

    /// Issues one active discovery request and ingests its responses.
    ///
    /// - Throws: ``GnosticTransportError`` when no session is running.
    func discover() async throws

    /// Observes catalog changes and connection loss for the lifetime of the transport.
    ///
    /// The returned stream is long-lived; a consumer iterates it until it cancels.
    func events() async -> AsyncStream<GnosticTransportEvent>

    /// Runs one identified remote Turn and streams its progress.
    ///
    /// The returned stream finishes after the Turn's terminal update. A stream that
    /// ends before a terminal update (connection loss, provider eviction) surfaces
    /// as `.failed` so a consumer never hangs on a dead Turn.
    ///
    /// - Throws: ``GnosticTransportError`` when no session is running or the Turn
    ///   cannot be started.
    func runTurn(_ request: GnosticTurnRequest) async throws -> AsyncStream<GnosticTurnEvent>

    /// Publishes a permission decision for a Turn started through this transport.
    ///
    /// The decision travels one way; the Ascendant records its resolution on the
    /// Turn's update stream.
    ///
    /// - Throws: ``GnosticTransportError`` when the Turn's serving provider cannot
    ///   be resolved.
    func respondToPermission(
        correlationID: String,
        approved: Bool,
        request: GnosticTurnRequest
    ) async throws

    /// Reports whether `workspaceID` can be attached without ambiguity.
    func workspaceAttachment(workspaceID: UUID) async throws -> GnosticWorkspaceAttachment

    /// Reports Gnostic's effective usability for `workspaceID`.
    func workspaceEffectiveStatus(workspaceID: UUID) async throws -> GnosticWorkspaceEffective

    /// Attaches a discovered Workspace to a Timeline.
    ///
    /// - Parameter approved: The caller's explicit user approval. `false` is
    ///   refused with ``GnosticTransportError/workspaceApprovalRequired`` before
    ///   any wire call.
    func attachWorkspace(workspaceID: UUID, to timelineID: UUID, approved: Bool) async throws

    /// Detaches an attached Workspace from a Timeline.
    func detachWorkspace(workspaceID: UUID, from timelineID: UUID) async throws
}
