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
/// toolCallID, agentID, executionKind, turnSnapshot, status) survive the round
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

    func toTimelineRecord(lifetime: TimelineLifetimeModel?) throws -> TimelineRecord {
        let forkedFrom: TimelineForkOrigin?
        do {
            forkedFrom = try lifetime?.forkedFromData.map {
                try JSONDecoder().decode(TimelineForkOrigin.self, from: $0)
            }
        } catch {
            throw PersistenceError.decoding("TimelineForkOrigin: \(error)")
        }
        return TimelineRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived,
            workingDirectory: workingDirectory,
            attachedAgentID: attachedAgentInstanceId,
            isPrivate: isPrivate,
            isEphemeral: lifetime?.isEphemeral ?? false,
            forkedFrom: forkedFrom
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
/// bookkeeping (admission, notices, correlations, intents, results) is delegated to an
/// in-process `InMemoryTimelineRuntimeRepository`.
///
/// Message writes are mirrored into that in-memory store, so the Turn bookkeeping
/// validates against the same history the durable rows hold. Turn membership is durable:
/// every Turn-owned message write saves its `TurnMessageMembershipModel` row in the same
/// `ModelContext.save()` as the message, so one transaction commits both or neither.
///
/// Message reads order by the stored `createdAt`; messages written with identical
/// timestamps have no append-order column, so their relative order is unspecified.
/// The upstream conformance ordering scenario passes; equal-timestamp ties outside
/// its fixtures are not guaranteed.
///
/// The split is deliberate: Yakamoz's UI reads durable Timeline/message rows
/// (`SwiftDataPromptInspector`, transcript reload), but it is a single-process,
/// single-user app that does not need crash recovery for in-flight Turn audit
/// trails. Durable Timeline rows are lazily rehydrated into the in-process
/// bookkeeping before Turn admission, so a fresh repository can resume existing
/// Timelines without claiming that in-flight Turns survived the restart.
/// `isDurable` reports `true` for the durable half; a future change that
/// needs durable Turn records can persist the same `Codable` values without
/// changing this seam.
///
/// **Failure ordering:** Turn lifecycle moves still mutate the in-memory
/// bookkeeping first and persist to SwiftData second (`admitTurn`,
/// `recordTurnMessage`, `recordToolResult(_:message:)`, `completeTurn`); message-only
/// writes (`saveMessage`) save durably first and mirror second. A SwiftData save failure
/// can therefore leave the bookkeeping ahead of disk for the life of the process;
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
        try stageLifetime(of: timeline)
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
            return try modelContext.fetch(descriptor).first?.toTimelineRecord(lifetime: lifetime(of: id))
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
            let lifetimes = try modelContext.fetch(FetchDescriptor<TimelineLifetimeModel>())
            let lifetimesByTimeline = Dictionary(uniqueKeysWithValues: lifetimes.map { ($0.timelineId, $0) })
            return try modelContext.fetch(descriptor).map { try $0.toTimelineRecord(lifetime: lifetimesByTimeline[$0.id]) }
        } catch {
            Log.runtime.warning("failed to fetch all Timelines", metadata: [
                "store": "TimelineRuntimeRepository",
            ])
            throw error
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        // Cascade: messages and their Turn membership go with the Timeline.
        try stageHistoryDeletion(ofTimeline: id)
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

    public func deleteEphemeralTimeline(id: UUID) async throws {
        var descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).first != nil else { return }
        guard try lifetime(of: id)?.isEphemeral == true else {
            throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: id)
        }
        try await deleteTimeline(id: id)
    }

    public func purgeEphemeralTimelines() async throws {
        let descriptor = FetchDescriptor<TimelineLifetimeModel>(predicate: #Predicate { $0.isEphemeral })
        for id in try modelContext.fetch(descriptor).map(\.timelineId) {
            try await deleteTimeline(id: id)
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
                try stageHistoryDeletion(ofTimeline: id)
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
        try await turnRuntime.saveMessage(message)
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
                let messageId = model.id
                try modelContext.delete(model: TurnMessageMembershipModel.self, where: #Predicate { $0.messageId == messageId })
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
            if let snapshot = try model.toTimelineMessage().turnSnapshot {
                snapshots.append(snapshot)
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
        try await ensureTimelineRegistered(timelineID)
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
            try persist(inputMessage, memberOf: admission.turn.identity.turnID)
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
        try await ensureTimelineRegistered(timelineID)
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
            try persist(inputMessage, memberOf: admission.turn.identity.turnID)
        }
        return admission
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try await turnRuntime.fetchTurn(id: id)
    }

    /// Reads the durable membership rows, falling back to the bookkeeping record only to
    /// tell a known message-free Turn (`[]`) from an unknown one (`nil`).
    public func fetchTurnMessages(turnID: UUID) async throws -> [TimelineMessage]? {
        let descriptor = FetchDescriptor<TurnMessageMembershipModel>(
            predicate: #Predicate { $0.turnId == turnID },
            sortBy: [SortDescriptor(\.ordinal)]
        )
        let memberIDs = try modelContext.fetch(descriptor).map(\.messageId)
        guard !memberIDs.isEmpty else {
            guard let recorded = try await turnRuntime.fetchTurn(id: turnID)?.memberMessageIDs else { return nil }
            if let missing = recorded.first {
                throw TimelineRuntimeRepositoryError.memberMessageMissing(turnID: turnID, messageID: missing)
            }
            return []
        }
        let models = try modelContext.fetch(FetchDescriptor<MessageModel>(predicate: #Predicate { memberIDs.contains($0.id) }))
        let modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        return try memberIDs.map { id in
            guard let model = modelsByID[id] else {
                throw TimelineRuntimeRepositoryError.memberMessageMissing(turnID: turnID, messageID: id)
            }
            return try model.toTimelineMessage()
        }
    }

    public func recordTurnMessage(_ message: TimelineMessage, turnID: UUID) async throws {
        try await turnRuntime.recordTurnMessage(message, turnID: turnID)
        try persist(message, memberOf: turnID)
    }

    public func fetchQuarantinedTurn(for timelineID: UUID) async throws -> TurnRecord? {
        try await turnRuntime.fetchQuarantinedTurn(for: timelineID)
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
        try persist(message, memberOf: result.turnID)
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
            try persist(finalMessage, memberOf: turnID)
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

    // MARK: - Helpers

    /// Rehydrates the durable Timeline identity needed by the in-memory admission state.
    /// Turn records remain process-local; only the Timeline registration is restored.
    private func ensureTimelineRegistered(_ timelineID: UUID) async throws {
        guard try await turnRuntime.fetchTimeline(id: timelineID) == nil else { return }

        var descriptor = FetchDescriptor<TimelineModel>(predicate: #Predicate { $0.id == timelineID })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        try await turnRuntime.saveTimeline(model.toTimelineRecord(lifetime: lifetime(of: timelineID)))
    }

    private func lifetime(of timelineID: UUID) throws -> TimelineLifetimeModel? {
        var descriptor = FetchDescriptor<TimelineLifetimeModel>(predicate: #Predicate { $0.timelineId == timelineID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Stages the lifetime row for `timeline`, removing it for an ordinary Timeline. The
    /// caller's save commits it with the Timeline row.
    private func stageLifetime(of timeline: TimelineRecord) throws {
        let existing = try lifetime(of: timeline.id)
        guard timeline.isEphemeral || timeline.forkedFrom != nil else {
            if let existing { modelContext.delete(existing) }
            return
        }
        let forkedFromData: Data?
        do {
            forkedFromData = try timeline.forkedFrom.map { try JSONEncoder().encode($0) }
        } catch {
            throw PersistenceError.encoding("TimelineForkOrigin: \(error)")
        }
        if let existing {
            existing.isEphemeral = timeline.isEphemeral
            existing.forkedFromData = forkedFromData
        } else {
            modelContext.insert(TimelineLifetimeModel(
                timelineId: timeline.id,
                isEphemeral: timeline.isEphemeral,
                forkedFromData: forkedFromData
            ))
        }
    }

    /// Stages the deletion of everything a Timeline owns other than its own row.
    private func stageHistoryDeletion(ofTimeline id: UUID) throws {
        try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == id })
        try modelContext.delete(model: TurnMessageMembershipModel.self, where: #Predicate { $0.timelineId == id })
        try modelContext.delete(model: TimelineLifetimeModel.self, where: #Predicate { $0.timelineId == id })
    }

    /// Persists one message with append-only semantics, and its Turn membership when
    /// `turnID` is given, in a single `ModelContext.save()`:
    ///
    /// - a message whose id is already stored is a no-op when it matches the stored
    ///   message ignoring `timestamp` (duplicate delivery), and throws
    ///   ``TimelineRuntimeRepositoryError/appendOnlyViolation(messageID:)`` when any
    ///   other field differs.
    /// - otherwise the message is inserted.
    ///
    /// A retried Turn adopts its predecessor's stored input, so a membership row can be
    /// new even when the message is not. A failed staging or save rolls back both inserts.
    private func persist(_ message: TimelineMessage, memberOf turnID: UUID? = nil) throws {
        let messageID = message.id
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.id == messageID })
        if let existing = try modelContext.fetch(descriptor).first {
            guard Self.messagesEquivalentIgnoringTimestamp(try existing.toTimelineMessage(), message) else {
                throw TimelineRuntimeRepositoryError.appendOnlyViolation(messageID: messageID)
            }
        } else {
            try modelContext.insert(MessageModel(message))
        }
        do {
            if let turnID {
                try stageMembership(of: message, in: turnID)
            }
            guard modelContext.hasChanges else { return }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.runtime.error("failed to save TimelineMessage", metadata: [
                "store": "TimelineRuntimeRepository",
                "timelineID": "\(message.timelineID)",
                "messageID": "\(message.id)",
            ])
            throw error
        }
    }

    private func stageMembership(of message: TimelineMessage, in turnID: UUID) throws {
        let messageID = message.id
        let rows = try modelContext.fetch(FetchDescriptor<TurnMessageMembershipModel>(
            predicate: #Predicate { $0.turnId == turnID }
        ))
        guard !rows.contains(where: { $0.messageId == messageID }) else { return }
        modelContext.insert(TurnMessageMembershipModel(
            turnId: turnID,
            messageId: messageID,
            timelineId: message.timelineID,
            ordinal: rows.count
        ))
    }

    private static func messagesEquivalentIgnoringTimestamp(
        _ lhs: TimelineMessage,
        _ rhs: TimelineMessage
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.timelineID == rhs.timelineID
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.parentID == rhs.parentID
            && lhs.reasoning == rhs.reasoning
            && lhs.toolCalls == rhs.toolCalls
            && lhs.toolCallID == rhs.toolCallID
            && lhs.agentID == rhs.agentID
            && lhs.executionKind == rhs.executionKind
            && lhs.remoteDepth == rhs.remoteDepth
            && lhs.turnSnapshot == rhs.turnSnapshot
            && lhs.status == rhs.status
    }
}
