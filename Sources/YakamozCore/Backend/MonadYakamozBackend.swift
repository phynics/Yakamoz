import ErrorKit
import Foundation
import MonadClient
import MonadShared
import PKShared
import PositronicKit

/// YAK-MON-3: the first concrete Monad-backed `YakamozBackend` slice, built on
/// `MonadClient`. Implements the health, timeline, and chat-streaming surfaces this
/// ticket is scoped to (`BackendHealthChecking`, `BackendTimelineListing`, `ChatRunning`)
/// — not the full `YakamozBackend` typealias. Agent/workspace/inspector conformance is
/// intentionally left to a later ticket rather than stubbed here (see
/// `MonadYakamozBackendStub`, which still covers that gap until the seam is complete).
///
/// All network access goes through the injected `MonadClientTransport`, so this type
/// contains no `URLSession`/transport code itself — just request composition and
/// response/error mapping. `LiveMonadClientTransport` is the production implementation;
/// tests inject a fully in-memory fake.
///
/// ## Manual smoke
///
/// Automated tests intentionally inject an in-memory `MonadClientTransport`. The authoritative
/// real-server procedure, including profile authentication, workspace RPC, streaming, inspector
/// limits, and recorded results, is `docs/monad-mode-manual-smoke.md`.
public struct MonadYakamozBackend: Sendable {
    /// `internal`, not `private`, so `MonadConnectionStatus.swift`'s
    /// `MonadYakamozBackend.fetchConnectionStatus()` extension (YAK-MON-9) can read it —
    /// matching the `ChatEngine`-adjacent convention of internal (not private) injected
    /// dependency fields for same-module extension files.
    let transport: any MonadClientTransport

    public init(transport: any MonadClientTransport) {
        self.transport = transport
    }

    /// Convenience initializer composing a `LiveMonadClientTransport`/`MonadClient` from
    /// the active `MonadProfile` and `SecretStoring` — the shape UI code actually reaches
    /// for once a profile is selected.
    public init(profile: MonadProfile, secrets: any SecretStoring) throws {
        let apiKey = try profile.apiKey(secrets: secrets)
        let configuration = ClientConfiguration(baseURL: profile.serverURL, apiKey: apiKey)
        let client = MonadClient(configuration: configuration)
        self.init(transport: LiveMonadClientTransport(client: client))
    }
}

// MARK: - BackendHealthChecking

extension MonadYakamozBackend: BackendHealthChecking {
    public func backendHealthCheck() async -> AppHealthStatus {
        do {
            return try await verifyReachable()
        } catch {
            return .down
        }
    }

    /// Same check as `backendHealthCheck()`, but surfaces the distinction between an
    /// unreachable server, an authentication failure, and an incompatible response via a
    /// typed error instead of collapsing everything to `.down`. `backendHealthCheck()`
    /// (the `BackendHealthChecking` conformance UI code drives) calls through this and
    /// maps any thrown error to `.down`.
    public func verifyReachable() async throws -> AppHealthStatus {
        do {
            let status = try await transport.getStatus()
            return AppHealthStatus(status.status)
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        } catch {
            throw MonadBackendHealthError.incompatibleResponse(underlying: "\(error)")
        }
    }
}

/// Typed health/status errors for `MonadYakamozBackend.verifyReachable()`, distinguishing
/// the three failure modes the ticket calls out: unreachable server, auth failure, and an
/// incompatible/unexpected response shape.
public enum MonadBackendHealthError: Error, Sendable, Equatable, LocalizedError {
    case unreachable(underlying: String)
    case authenticationFailed
    case incompatibleResponse(underlying: String)

    init(clientError: MonadClientError) {
        switch clientError {
        case .networkError, .serverNotReachable:
            self = .unreachable(underlying: clientError.userFriendlyMessage)
        case .unauthorized:
            self = .authenticationFailed
        case .invalidURL, .decodingError, .httpError, .notFound, .unknown:
            self = .incompatibleResponse(underlying: clientError.userFriendlyMessage)
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unreachable(underlying):
            "The Monad server is not reachable: \(underlying)"
        case .authenticationFailed:
            "The Monad server rejected the configured API key."
        case let .incompatibleResponse(underlying):
            "The Monad server returned an unexpected response: \(underlying)"
        }
    }
}

// MARK: - BackendTimelineListing

extension MonadYakamozBackend: BackendTimelineListing {
    public func listTimelines() async throws -> [BackendTimelineSummary] {
        do {
            let timelines = try await transport.listTimelines()
            return timelines.map(BackendTimelineSummary.init(monadTimeline:))
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    public func createTimeline(title: String) async throws -> BackendTimelineSummary {
        do {
            let timeline = try await transport.createTimeline(title: title)
            return BackendTimelineSummary(monadTimeline: timeline)
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    public func loadTimeline(id: UUID) async throws -> BackendTimelineSummary? {
        do {
            let timeline = try await transport.getTimeline(id: id)
            return BackendTimelineSummary(monadTimeline: timeline)
        } catch MonadClientError.notFound {
            return nil
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }
}

private extension BackendTimelineSummary {
    init(monadTimeline: TimelineResponse) {
        self.init(
            id: monadTimeline.id,
            title: monadTimeline.title ?? "Untitled",
            createdAt: monadTimeline.createdAt
        )
    }
}

// MARK: - BackendInspectorProviding (YAK-MON-8)

extension MonadYakamozBackend: BackendInspectorProviding {
    /// A limited inspector is available for Monad-backed turns: response metadata, tool
    /// traces, and workspace files are sourced from the live `ChatTurnState` (no local
    /// persistence). The prompt/sent/journal tabs are not available because Monad does not
    /// expose the prompt assembly pipeline, sent payload, or journal diffs.
    public var inspectorAvailable: Bool {
        true
    }
}

// MARK: - ChatRunning

extension MonadYakamozBackend: ChatRunning {
    /// Streams one chat turn against the configured Monad server. Maps the
    /// transport-neutral `ChatRunRequest` directly onto `MonadChatClient.execute`, which
    /// already decodes SSE frames into `PKShared.ChatEvent` — the exact type
    /// `ChatRunning` expects — so no separate event-translation layer is needed here.
    public func run(_ request: ChatRunRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            return try await transport.execute(
                timelineId: request.timelineId,
                message: request.message,
                toolOutputs: request.toolOutputs,
                clientTools: nil
            )
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }
}

// MARK: - MonadAgentListing

extension MonadYakamozBackend: MonadAgentListing {
    /// Server agent *instances* (live agents with their own workspace/private timeline).
    public func listAgentInstances() async throws -> [MonadAgentSummary] {
        do {
            let instances = try await transport.listAgentInstances()
            return instances.map(MonadAgentSummary.init(instance:))
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    /// Server agent *templates* (reusable definitions an instance can be created from).
    public func listAgentTemplates() async throws -> [MonadAgentSummary] {
        do {
            let templates = try await transport.listAgentTemplates()
            return templates.map(MonadAgentSummary.init(template:))
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    /// Timelines belonging to a given server agent instance.
    public func listTimelines(forAgent agentId: UUID) async throws -> [BackendTimelineSummary] {
        do {
            let timelines = try await transport.getAgentTimelines(agentId: agentId)
            return timelines.map(BackendTimelineSummary.init(monadTimeline:))
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }
}

private extension MonadAgentSummary {
    init(instance: AgentInstance) {
        self.init(id: instance.id, kind: .instance, name: instance.name, description: instance.description)
    }

    init(template: AgentTemplate) {
        self.init(id: template.id, kind: .template, name: template.name, description: template.description)
    }
}

// MARK: - BackendWorkspaceManaging (YAK-MON-6)

extension MonadYakamozBackend: BackendWorkspaceManaging {
    public func listWorkspaces() async throws -> [BackendWorkspaceSummary] {
        do {
            let workspaces = try await transport.listWorkspaces()
            return workspaces.map(BackendWorkspaceSummary.init(workspace:))
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    public func attachWorkspace(_ workspaceId: UUID, toTimeline timelineId: UUID) async throws {
        do {
            try await transport.attachWorkspace(workspaceId, to: timelineId)
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    public func detachWorkspace(_ workspaceId: UUID, fromTimeline timelineId: UUID) async throws {
        do {
            try await transport.detachWorkspace(workspaceId, from: timelineId)
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }

    /// Monad-specific: fetches the primary and attached workspaces for one timeline from
    /// the server. Returns the full `WorkspaceReference` shape (not the minimal
    /// `BackendWorkspaceSummary`) so the UI can display status, root path, and terminal
    /// availability — data the narrow `BackendWorkspaceManaging` protocol intentionally
    /// drops. Server is authoritative; nothing is cached locally.
    public func listTimelineWorkspaces(timelineId: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
        do {
            return try await transport.listTimelineWorkspaces(timelineId: timelineId)
        } catch let error as MonadClientError {
            throw MonadBackendHealthError(clientError: error)
        }
    }
}

private extension BackendWorkspaceSummary {
    init(workspace: WorkspaceReference) {
        let name: String
        if let rootPath = workspace.rootPath, !rootPath.isEmpty {
            name = (rootPath as NSString).lastPathComponent
        } else {
            let pathComponent = (workspace.uri.path as NSString).lastPathComponent
            name = pathComponent.isEmpty ? workspace.uri.description : pathComponent
        }
        self.init(id: workspace.id, displayName: name)
    }
}
