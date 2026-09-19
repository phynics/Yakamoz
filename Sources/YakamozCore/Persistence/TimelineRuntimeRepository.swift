import Foundation
import Logging
import PKContracts
import PositronicKit
import SwiftData

/// Error domain for YakamozCore's SwiftData persistence adapters.
public enum PersistenceError: Error, Sendable {
    case encoding(String)
    case decoding(String)
}

extension MessageModel {
    convenience init(_ message: TimelineMessage) throws {
        let messageEnvelopeData: Data?
        do {
            messageEnvelopeData = try JSONEncoder().encode(MessageStoreEnvelope(message: message))
        } catch {
            throw PersistenceError.encoding("TimelineMessage envelope: \(error)")
        }
        self.init(
            id: message.id,
            conversationId: message.timelineID,
            role: message.role,
            content: message.content,
            messageEnvelopeData: messageEnvelopeData,
            createdAt: message.timestamp,
            remoteDepth: message.remoteDepth
        )
    }

    func toTimelineMessage() throws -> TimelineMessage {
        guard let messageEnvelopeData else {
            return TimelineMessage(
                id: id,
                timelineID: conversationId,
                role: Message.MessageRole(rawValue: role) ?? .user,
                content: content,
                timestamp: createdAt,
                remoteDepth: remoteDepth
            )
        }
        let envelope: MessageStoreEnvelope
        do {
            envelope = try JSONDecoder().decode(MessageStoreEnvelope.self, from: messageEnvelopeData)
        } catch {
            throw PersistenceError.decoding("TimelineMessage envelope: \(error)")
        }
        var message = envelope.message
        // The model's scalar columns are authoritative for queryable fields;
        // the envelope carries everything else.
        message.id = id
        message.timelineID = conversationId
        message.content = content
        message.timestamp = createdAt
        message.remoteDepth = remoteDepth
        return message
    }
}

/// Wraps the full `TimelineMessage` so non-scalar fields (reasoning, toolCalls,
/// toolCallID, agentID, executionKind, snapshotData, status) survive the round
/// trip through `MessageModel.messageEnvelopeData`.
private struct MessageStoreEnvelope: Codable {
    var message: TimelineMessage
}

extension TimelineModel {
    convenience init(_ timeline: TimelineRecord) throws {
        self.init(
            id: timeline.id,
            title: timeline.title,
            createdAt: timeline.createdAt,
            updatedAt: timeline.updatedAt,
            isArchived: timeline.isArchived,
            workingDirectory: timeline.workingDirectory,
            attachedWorkspaceIdsData: try JSONEncoder().encode([UUID]()),
            attachedAgentInstanceId: timeline.attachedAgentID,
            isPrivate: timeline.isPrivate
        )
    }

    func toTimelineRecord() -> TimelineRecord {
        TimelineRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived,
            workingDirectory: workingDirectory,
            attachedAgentID: attachedAgentInstanceId,
            isPrivate: isPrivate
        )
    }

    /// Applies the mutable fields of `timeline` onto this existing model, in place
    /// (used by `saveTimeline` upsert semantics so identity/relationships aren't lost).
    func update(from timeline: TimelineRecord) {
        title = timeline.title
        createdAt = timeline.createdAt
        updatedAt = timeline.updatedAt
        isArchived = timeline.isArchived
        workingDirectory = timeline.workingDirectory
        attachedAgentInstanceId = timeline.attachedAgentID
        isPrivate = timeline.isPrivate
    }
}

/// SwiftData-backed `TimelineRuntimeRepository`: Timeline identity and message
/// history are durable rows in the shared `ModelContainer`, while Turn lifecycle
/// bookkeeping (admission, notices, correlations, intents, results, summaries)
/// is delegated to an in-process `InMemoryTimelineRuntimeRepository`.
///
/// The split is deliberate: Yakamoz's UI reads durable Timeline/message rows
/// (`SwiftDataPromptInspector`, transcript reload), but it is a single-process,
/// single-user app that does not need crash recovery for in-flight Turn audit
/// trails. `isDurable` reports `true` for the durable half; a future change that
/// needs durable Turn records can persist the same `Codable` values without
/// changing this seam.
///
/// **Failure ordering:** moves that span both halves mutate the in-memory
/// bookkeeping first and persist to SwiftData second (`admitTurn`,
/// `recordToolResult(_:message:)`, `completeTurn`). A SwiftData save failure can
/// therefore leave the bookkeeping ahead of disk for the life of the process;
/// the durable migration is tracked by running the upstream
/// `TimelineRuntimeRepositoryConformanceSuite` against this adapter.
@ModelActor
public actor SwiftDataTimelineRuntimeRepository: TimelineRuntimeRepository {
    public nonisolated let isDurable = true

    private let turnRuntime = InMemoryTimelineRuntimeRepository()

    // MARK: - TimelinePersistenceProtocol

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        let id = timeline.id
        let descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: timeline)
        } else {
            try modelContext.insert(TimelineModel(timeline))
        }
        do {
            try modelContext.save()
            // Turn admission validates Timeline existence against the bookkeeping
            // repository, so the record must exist there too.
            try await turnRuntime.saveTimeline(timeline)
        } catch {
            Log.runtime.error("failed to save Timeline", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        var descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first?.toTimelineRecord()
        } catch {
            Log.runtime.warning("failed to fetch Timeline", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        let descriptor: FetchDescriptor<TimelineModel>
        if includeArchived {
            descriptor = FetchDescriptor<TimelineModel>(sortBy: [SortDescriptor(\.createdAt)])
        } else {
            descriptor = FetchDescriptor<TimelineModel>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        }
        do {
            return try modelContext.fetch(descriptor).map { $0.toTimelineRecord() }
        } catch {
            Log.runtime.warning("failed to fetch all Timelines", metadata: [
                "store": "TimelineRuntimeRepository",
            ])
            throw error
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        // Cascade: messages and summaries go with the Timeline.
        try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == id })
        try modelContext.delete(model: TimelineModel.self, where: #Predicate { $0.id == id })
        do {
            try modelContext.save()
            try await turnRuntime.deleteTimeline(id: id)
        } catch {
            Log.runtime.error("failed to delete Timeline", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(id)",
            ])
            throw error
        }
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.updatedAt < cutoff })
        let candidates = try modelContext.fetch(descriptor).filter { !excludedTimelineIDs.contains($0.id) }
        if !dryRun {
            for model in candidates {
                let id = model.id
                modelContext.delete(model)
                // Cascade: a pruned Timeline must not leave unreachable history behind.
                try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == id })
            }
            do {
                try modelContext.save()
                for model in candidates {
                    try await turnRuntime.deleteTimeline(id: model.id)
                }
            } catch {
                Log.runtime.error("failed to prune Timelines", metadata: [
                    "store": "TimelineRuntimeRepository",
                    "count": "\(candidates.count)",
                ])
                throw error
            }
        }
        return candidates.count
    }

    // MARK: - TimelineMessageStoreProtocol

    public func saveMessage(_ message: TimelineMessage) async throws {
        try persist(message)
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            return try modelContext.fetch(descriptor).map { try $0.toTimelineMessage() }
        } catch {
            Log.runtime.warning("failed to fetch TimelineMessages", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(timelineID)",
            ])
            throw error
        }
    }

    public func deleteMessages(for timelineID: UUID) async throws {
        throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: timelineID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.createdAt < cutoff })
        let matches = try modelContext.fetch(descriptor)
        if !dryRun {
            for model in matches {
                modelContext.delete(model)
            }
            do {
                try modelContext.save()
            } catch {
                Log.runtime.error("failed to prune TimelineMessages", metadata: [
                    "store": "TimelineRuntimeRepository",
                    "count": "\(matches.count)",
                ])
                throw error
            }
        }
        return matches.count
    }

    public func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let models = try modelContext.fetch(descriptor)
        var snapshots: [TurnSnapshot] = []
        for model in models {
            let message = try model.toTimelineMessage()
            guard let data = message.snapshotData else { continue }
            do {
                try snapshots.append(JSONDecoder().decode(TurnSnapshot.self, from: data))
            } catch {
                throw PersistenceError.decoding("TurnSnapshot: \(error)")
            }
        }
        return snapshots
    }

    // MARK: - Turn lifecycle (delegated, ephemeral)

    public func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        let admission = try await turnRuntime.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
        if admission.disposition == .admitted, let inputMessage {
            try persist(inputMessage)
        }
        return admission
    }

    public func admitRetry(
        timelineID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) async throws -> TurnAdmission {
        let admission = try await turnRuntime.admitRetry(
            timelineID: timelineID,
            previousTurnID: previousTurnID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            attempt: attempt,
            now: now
        )
        if admission.disposition == .admitted, let inputMessage {
            try persist(inputMessage)
        }
        return admission
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try await turnRuntime.fetchTurn(id: id)
    }

    public func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        try await turnRuntime.fetchActiveTurn(for: timelineID)
    }

    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        try await turnRuntime.appendNotice(turnID: turnID, notice: notice)
    }

    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        try await turnRuntime.appendCorrelation(turnID: turnID, correlation: correlation, now: now)
    }

    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try await turnRuntime.fetchNotices(turnID: turnID)
    }

    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try await turnRuntime.fetchCorrelations(turnID: turnID)
    }

    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        try await turnRuntime.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now)
    }

    public func recordProviderRequest(
        turnID: UUID,
        modelRoundIndex: Int,
        correlation: TurnCorrelation?,
        now: Date
    ) async throws {
        try await turnRuntime.recordProviderRequest(
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            correlation: correlation,
            now: now
        )
    }

    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        try await turnRuntime.recordToolIntent(intent)
    }

    public func recordToolResult(_ result: RuntimeToolResult) async throws {
        try await turnRuntime.recordToolResult(result)
    }

    public func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
        try await turnRuntime.recordToolResult(result, message: message)
        try persist(message)
    }

    public func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] {
        try await turnRuntime.fetchToolIntents(turnID: turnID)
    }

    public func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] {
        try await turnRuntime.fetchToolResults(turnID: turnID)
    }

    public func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord {
        let record = try await turnRuntime.completeTurn(
            turnID: turnID,
            outcome: outcome,
            finalMessage: finalMessage,
            terminalHandle: terminalHandle,
            now: now
        )
        // Only the first, winning completion appends its final message; a late
        // first-writer-wins call reports the original record and must not duplicate it.
        if let finalMessage, record.terminalMessageID == finalMessage.id {
            try persist(finalMessage)
        }
        return record
    }

    public func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult {
        try await turnRuntime.interruptTurn(
            turnID: turnID,
            reason: reason,
            disposition: disposition,
            now: now
        )
    }

    public func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord {
        try await turnRuntime.releaseQuarantine(
            timelineID: timelineID,
            turnID: turnID,
            confirmation: confirmation,
            now: now
        )
    }

    public func saveSummary(_ summary: TimelineSummary) async throws {
        try await turnRuntime.saveSummary(summary)
    }

    public func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] {
        try await turnRuntime.fetchSummaries(for: timelineID)
    }

    // MARK: - Helpers

    private func persist(_ message: TimelineMessage) throws {
        let model = try MessageModel(message)
        modelContext.insert(model)
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save TimelineMessage", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(message.timelineID)",
                "messageID": "\(message.id)",
            ])
            throw error
        }
    }
}
