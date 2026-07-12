import Foundation
import MonadClient
import MonadShared
import PKShared

/// The narrow slice of `MonadClient` that `MonadYakamozBackend` actually drives: status,
/// timeline list/create/load, and one chat-turn stream.
///
/// `MonadClient` itself is a concrete `actor`, and its streaming call
/// (`MonadChatClient.execute`) returns bytes via `URLSession.AsyncBytes` under the hood — a
/// concrete Foundation type that cannot be hand-constructed in a test double. Rather than
/// fake at the `URLSessionProtocol` layer (which would still require a real `AsyncBytes`
/// for the streaming path), this protocol seam sits one level up: `LiveMonadClientTransport`
/// wraps a real `MonadClient`, while tests inject a fully in-memory fake conforming to this
/// protocol, so `MonadYakamozBackend`'s mapping/error-translation logic is exercised with no
/// network involved.
public protocol MonadClientTransport: Sendable {
    func getStatus() async throws -> StatusResponse
    func listTimelines() async throws -> [TimelineResponse]
    func createTimeline(title: String?) async throws -> Timeline
    func getTimeline(id: UUID) async throws -> TimelineResponse
    func execute(
        timelineId: UUID,
        message: String,
        toolOutputs: [ToolOutputSubmission]?,
        clientTools: [ToolReference]?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error>

    // MARK: - YAK-MON-4: server agent instances/templates

    func listAgentInstances() async throws -> [AgentInstance]
    func listAgentTemplates() async throws -> [AgentTemplate]
    func getAgentTimelines(agentId: UUID) async throws -> [TimelineResponse]

    // MARK: - YAK-MON-6: server workspace management

    func listWorkspaces() async throws -> [WorkspaceReference]
    func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws
    func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws
    func listTimelineWorkspaces(timelineId: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference])
}

/// Live `MonadClientTransport` wrapping a real `MonadClient` actor.
public struct LiveMonadClientTransport: MonadClientTransport {
    private let client: MonadClient

    public init(client: MonadClient) {
        self.client = client
    }

    public func getStatus() async throws -> StatusResponse {
        try await client.getStatus()
    }

    public func listTimelines() async throws -> [TimelineResponse] {
        try await client.chat.listTimelines()
    }

    public func createTimeline(title: String?) async throws -> Timeline {
        try await client.chat.createTimeline(title: title)
    }

    public func getTimeline(id: UUID) async throws -> TimelineResponse {
        try await client.chat.getTimeline(id: id)
    }

    public func execute(
        timelineId: UUID,
        message: String,
        toolOutputs: [ToolOutputSubmission]?,
        clientTools: [ToolReference]?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await client.chat.execute(
            timelineId: timelineId,
            message: message,
            toolOutputs: toolOutputs,
            clientTools: clientTools
        )
    }

    // MARK: - YAK-MON-4: server agent instances/templates

    public func listAgentInstances() async throws -> [AgentInstance] {
        try await client.chat.listAgentInstances()
    }

    public func listAgentTemplates() async throws -> [AgentTemplate] {
        try await client.chat.listAgentTemplates()
    }

    public func getAgentTimelines(agentId: UUID) async throws -> [TimelineResponse] {
        try await client.chat.getAgentTimelines(agentId: agentId)
    }

    // MARK: - YAK-MON-6: server workspace management

    public func listWorkspaces() async throws -> [WorkspaceReference] {
        try await client.workspace.listWorkspaces()
    }

    public func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        try await client.workspace.attachWorkspace(workspaceId, to: timelineId)
    }

    public func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        try await client.workspace.detachWorkspace(workspaceId, from: timelineId)
    }

    public func listTimelineWorkspaces(timelineId: UUID) async throws -> (primary: WorkspaceReference?, attached: [WorkspaceReference]) {
        try await client.workspace.listTimelineWorkspaces(timelineId: timelineId)
    }
}
