import Foundation
import PKContracts
import PositronicKit
import SwiftData

/// Local-mode `YakamozBackend`: wraps the existing `ConversationCoordinator`/SwiftData
/// behavior (plus an injected `ChatRunning`/health collaborator, normally the app's
/// `YakamozRuntime`) behind the backend seam, without changing local-mode behavior.
///
/// Deliberately depends on narrow collaborator protocols (`ChatRunning`,
/// `BackendHealthChecking`) plus a `ModelContainer`/`TimelinePersistenceProtocol` pair —
/// not the concrete `YakamozRuntime` type — so unit tests can exercise it with a
/// scripted fake runner/health check and an in-memory `ModelContainer`, with no real
/// network call and no real `YakamozRuntime` instantiated.
public struct LocalYakamozBackend: YakamozBackend {
    private let chatRunner: any ChatRunning
    private let health: any BackendHealthChecking
    private let modelContainer: ModelContainer
    private let timelineStore: any ThreadPersistenceProtocol
    public let inspectorAvailable: Bool

    public init(
        chatRunner: any ChatRunning,
        health: any BackendHealthChecking,
        modelContainer: ModelContainer,
        timelineStore: any ThreadPersistenceProtocol,
        inspectorAvailable: Bool = true
    ) {
        self.chatRunner = chatRunner
        self.health = health
        self.modelContainer = modelContainer
        self.timelineStore = timelineStore
        self.inspectorAvailable = inspectorAvailable
    }

    // MARK: - BackendHealthChecking

    public func backendHealthCheck() async -> AppHealthStatus {
        await health.backendHealthCheck()
    }

    // MARK: - ChatRunning

    public func run(_ request: TurnRequest) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await chatRunner.run(request)
    }

    // MARK: - BackendTimelineListing

    @MainActor
    public func listTimelines() async throws -> [BackendTimelineSummary] {
        let coordinator = makeCoordinator()
        return try coordinator.fetchStandardConversations().map(Self.summary(for:))
    }

    @MainActor
    public func createTimeline(title: String) async throws -> BackendTimelineSummary {
        let coordinator = makeCoordinator()
        let conversation = try await coordinator.createConversation(title: title)
        return Self.summary(for: conversation)
    }

    @MainActor
    public func loadTimeline(id: UUID) async throws -> BackendTimelineSummary? {
        var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let conversation = try modelContainer.mainContext.fetch(descriptor).first else { return nil }
        return Self.summary(for: conversation)
    }

    // MARK: - BackendAgentSelecting

    @MainActor
    public func listAgents() async throws -> [BackendAgentSummary] {
        let descriptor = FetchDescriptor<AgentModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContainer.mainContext.fetch(descriptor).map { BackendAgentSummary(id: $0.id, name: $0.name) }
    }

    @MainActor
    public func selectAgent(_ agentId: UUID?, forTimeline timelineId: UUID) async throws {
        let coordinator = makeCoordinator()
        try await coordinator.setOperator(conversationId: timelineId, agentId: agentId)
    }

    // MARK: - BackendWorkspaceManaging

    @MainActor
    public func listWorkspaces() async throws -> [BackendWorkspaceSummary] {
        let descriptor = FetchDescriptor<WorkspaceModel>(sortBy: [SortDescriptor(\.displayName)])
        return try modelContainer.mainContext.fetch(descriptor).map { BackendWorkspaceSummary(id: $0.id, displayName: $0.displayName) }
    }

    @MainActor
    public func attachWorkspace(_ workspaceId: UUID, toTimeline timelineId: UUID) async throws {
        try updateAttachedWorkspaceIds(forTimeline: timelineId) { ids in
            if !ids.contains(workspaceId) { ids.append(workspaceId) }
        }
    }

    @MainActor
    public func detachWorkspace(_ workspaceId: UUID, fromTimeline timelineId: UUID) async throws {
        try updateAttachedWorkspaceIds(forTimeline: timelineId) { ids in
            ids.removeAll { $0 == workspaceId }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator() -> ConversationCoordinator {
        ConversationCoordinator(modelContext: modelContainer.mainContext, timelineStore: timelineStore)
    }

    @MainActor
    private func updateAttachedWorkspaceIds(forTimeline timelineId: UUID, mutate: (inout [UUID]) -> Void) throws {
        var descriptor = FetchDescriptor<ConversationModel>(predicate: #Predicate { $0.id == timelineId })
        descriptor.fetchLimit = 1
        guard let conversation = try modelContainer.mainContext.fetch(descriptor).first else {
            throw LocalBackendError.timelineNotFound
        }
        var ids = conversation.attachedWorkspaceIds
        mutate(&ids)
        conversation.attachedWorkspaceIds = ids
        try modelContainer.mainContext.save()
    }

    private static func summary(for conversation: ConversationModel) -> BackendTimelineSummary {
        BackendTimelineSummary(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            isHomeTimeline: conversation.isHomeTimeline
        )
    }
}

public enum LocalBackendError: Error, Sendable, Equatable, LocalizedError {
    case timelineNotFound

    public var errorDescription: String? {
        switch self {
        case .timelineNotFound: "Timeline not found."
        }
    }
}
