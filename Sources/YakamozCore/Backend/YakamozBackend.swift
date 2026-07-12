import Foundation
import PositronicKit

// YAK-MON-2: the backend seam so UI/view models can eventually run against either the
// existing local runtime (`LocalYakamozBackend`) or a future Monad-backed adapter
// (`MonadYakamozBackendStub`, concrete transport lands in a later ticket) without
// forcing server concepts into the local model.
//
// Each sub-protocol below covers exactly one surface the UI needs. They compose into
// `YakamozBackend` via a typealias rather than one fat protocol, so a fake backend used
// in tests only has to implement what a given test actually exercises when constructed
// through a narrower alias.

/// App-safe summary of a chat timeline/conversation, independent of the SwiftData
/// `ConversationModel` type so a Monad-backed adapter can produce the same shape from a
/// server response with no local persistence involved.
public struct BackendTimelineSummary: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let isHomeTimeline: Bool

    public init(id: UUID, title: String, createdAt: Date, isHomeTimeline: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.isHomeTimeline = isHomeTimeline
    }
}

/// App-safe summary of an agent/operator that can be selected onto a timeline.
public struct BackendAgentSummary: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// App-safe summary of an attachable workspace.
public struct BackendWorkspaceSummary: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Backend/server-agnostic health surface for the settings/status UI (mirrors
/// `YakamozRuntime.appHealthCheck()`, boxed behind a narrow protocol so a fake backend
/// can answer without a real `LLMStreamClient`).
public protocol BackendHealthChecking: Sendable {
    func backendHealthCheck() async -> AppHealthStatus
}

/// Timeline list/create/load surface.
public protocol BackendTimelineListing: Sendable {
    func listTimelines() async throws -> [BackendTimelineSummary]
    func createTimeline(title: String) async throws -> BackendTimelineSummary
    func loadTimeline(id: UUID) async throws -> BackendTimelineSummary?
}

/// Agent list/select surface — "select" here means assigning (or clearing) a timeline's
/// operator agent, mirroring `YakamozRuntime.setOperator`.
public protocol BackendAgentSelecting: Sendable {
    func listAgents() async throws -> [BackendAgentSummary]
    func selectAgent(_ agentId: UUID?, forTimeline timelineId: UUID) async throws
}

/// Workspace list/attach/detach surface.
public protocol BackendWorkspaceManaging: Sendable {
    func listWorkspaces() async throws -> [BackendWorkspaceSummary]
    func attachWorkspace(_ workspaceId: UUID, toTimeline timelineId: UUID) async throws
    func detachWorkspace(_ workspaceId: UUID, fromTimeline timelineId: UUID) async throws
}

/// Whether the turn-inspector ("prompt pipeline under glass") tab has anything to show
/// for this backend. Local mode always does (`SwiftDataPromptInspector`); a Monad-backed
/// adapter may not until a later ticket wires a remote inspector surface.
public protocol BackendInspectorProviding: Sendable {
    var inspectorAvailable: Bool { get }
}

/// The full backend seam. `ChatRunning` (already the seam `ChatViewModel` runs turns
/// through) supplies "stream a user turn" so this ticket does not invent a second,
/// parallel streaming protocol.
public typealias YakamozBackend = BackendAgentSelecting
    &
    BackendHealthChecking
    & BackendInspectorProviding
    & BackendTimelineListing
    & BackendWorkspaceManaging
    & ChatRunning
