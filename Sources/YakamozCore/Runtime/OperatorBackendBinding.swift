import Foundation
import PositronicKit
import SwiftData

/// Owns the Local-backend relationship between a Yakamoz operator and the
/// PositronicKit runtime instance required by executable timelines.
@MainActor
public struct OperatorBackendBinding {
    private let modelContext: ModelContext
    private let timelineStore: any TimelinePersistenceProtocol

    public init(modelContext: ModelContext, timelineStore: any TimelinePersistenceProtocol) {
        self.modelContext = modelContext
        self.timelineStore = timelineStore
    }

    public func ensureBackendInstance(for operatorModel: OperatorModel) async throws -> UUID {
        if let backendInstanceId = operatorModel.backendInstanceId {
            return backendInstanceId
        }

        let backendInstanceId = operatorModel.id
        let privateTimelineId = UUID()
        let template = AgentTemplateModel(
            id: backendInstanceId,
            name: operatorModel.name,
            templateDescription: "Operator: \(operatorModel.name)",
            systemPrompt: operatorModel.instructions
        )
        let instance = AgentInstanceModel(
            id: backendInstanceId,
            name: operatorModel.name,
            instanceDescription: operatorModel.instructions,
            privateTimelineId: privateTimelineId
        )
        modelContext.insert(template)
        modelContext.insert(instance)
        operatorModel.backendInstanceId = backendInstanceId
        try modelContext.save()

        try await timelineStore.saveTimeline(Timeline(
            id: privateTimelineId,
            title: "[\(operatorModel.name)] Private",
            attachedAgentInstanceId: backendInstanceId,
            isPrivate: true
        ))
        return backendInstanceId
    }

    public func attachOperator(_ operatorModel: OperatorModel, to timelineId: UUID) async throws {
        let backendInstanceId = try await ensureBackendInstance(for: operatorModel)
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineId) else { return }
        timeline.attachedAgentInstanceId = backendInstanceId
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)
    }

    public func detachOperator(from timelineId: UUID) async throws {
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineId) else { return }
        timeline.attachedAgentInstanceId = nil
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)
    }
}
