import Foundation
import PKContracts
import PositronicKit

/// Placeholder Monad-backed `YakamozBackend`. Concrete HTTP/SSE transport against a
/// running Monad server lands in a later YAK-MON ticket; this stub exists so callers
/// can compile/select against the seam today (via `OperationMode`/`MonadProfile`,
/// YAK-MON-1) without a real backend being wired in yet. Every operation throws
/// `MonadBackendUnavailable` (or reports the least-capable answer for a non-throwing
/// requirement) rather than silently no-op'ing, so a caller that mistakenly selects
/// Monad mode before the real adapter lands fails loudly instead of behaving like an
/// empty local workspace.
public struct MonadYakamozBackendStub: YakamozBackend {
    public init() {}

    public var inspectorAvailable: Bool {
        false
    }

    public func backendHealthCheck() async -> AppHealthStatus {
        .down
    }

    public func run(_: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        throw MonadBackendUnavailable()
    }

    public func listTimelines() async throws -> [BackendTimelineSummary] {
        throw MonadBackendUnavailable()
    }

    public func createTimeline(title _: String) async throws -> BackendTimelineSummary {
        throw MonadBackendUnavailable()
    }

    public func loadTimeline(id _: UUID) async throws -> BackendTimelineSummary? {
        throw MonadBackendUnavailable()
    }

    public func listAgents() async throws -> [BackendAgentSummary] {
        throw MonadBackendUnavailable()
    }

    public func selectAgent(_: UUID?, forTimeline _: UUID) async throws {
        throw MonadBackendUnavailable()
    }

    public func listWorkspaces() async throws -> [BackendWorkspaceSummary] {
        throw MonadBackendUnavailable()
    }

    public func attachWorkspace(_: UUID, toTimeline _: UUID) async throws {
        throw MonadBackendUnavailable()
    }

    public func detachWorkspace(_: UUID, fromTimeline _: UUID) async throws {
        throw MonadBackendUnavailable()
    }
}

/// Thrown by every `MonadYakamozBackendStub` operation until the real Monad transport
/// (HTTP/SSE against `MonadClient`) lands in a later ticket.
public struct MonadBackendUnavailable: Error, Sendable, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Monad backend is not yet implemented."
    }
}
