import Foundation
import PKShared
import PositronicKit
import SwiftData

/// Error domain for YakamozCore's SwiftData persistence adapters.
///
/// Adapters store nested `Codable` PositronicKit payloads as `Data` inside
/// `@Model` entities; these errors surface JSON encode/decode failures at the
/// adapter boundary rather than silently dropping or defaulting the data.
public enum PersistenceError: Error, Sendable {
    case encoding(String)
    case decoding(String)
}

extension MessageModel {
    convenience init(_ message: ConversationMessage) throws {
        let toolCallsData: Data?
        do {
            toolCallsData = try JSONEncoder().encode(MessageStoreEnvelope(message: message))
        } catch {
            throw PersistenceError.encoding("ConversationMessage envelope: \(error)")
        }
        self.init(
            id: message.id,
            conversationId: message.timelineId,
            role: message.role,
            content: message.content,
            toolCallsData: toolCallsData,
            createdAt: message.timestamp,
            remoteDepth: message.remoteDepth
        )
    }

    func toConversationMessage() throws -> ConversationMessage {
        guard let toolCallsData else {
            return ConversationMessage(
                id: id,
                timelineId: conversationId,
                role: Message.MessageRole(rawValue: role) ?? .user,
                content: content,
                timestamp: createdAt,
                remoteDepth: remoteDepth
            )
        }
        let envelope: MessageStoreEnvelope
        do {
            envelope = try JSONDecoder().decode(MessageStoreEnvelope.self, from: toolCallsData)
        } catch {
            throw PersistenceError.decoding("ConversationMessage envelope: \(error)")
        }
        var message = envelope.message
        // The model's scalar columns are authoritative for queryable fields;
        // the envelope carries everything else.
        message.id = id
        message.timelineId = conversationId
        message.content = content
        message.timestamp = createdAt
        message.remoteDepth = remoteDepth
        return message
    }
}

/// Wraps the full `ConversationMessage` so non-scalar fields (recalledMemories,
/// parentId, think, toolCalls, toolCallId, agentInstanceId, snapshotData) survive
/// the round trip through `MessageModel.toolCallsData`, despite the field's name
/// only describing one of those fields historically.
private struct MessageStoreEnvelope: Codable {
    var message: ConversationMessage
}

/// `MessageStoreProtocol` adapter that confines a SwiftData `ModelContext` to
/// persist `ConversationMessage` values as `MessageModel` rows.
///
/// `ModelContext` is not `Sendable`; `@ModelActor` confines it to this actor so
/// every method can do its `FetchDescriptor`/mapping/save inside the actor and
/// return only `Sendable` PositronicKit values across the boundary.
@ModelActor
public actor SwiftDataMessageStore: MessageStoreProtocol {
    public func saveMessage(_ message: ConversationMessage) async throws {
        let model = try MessageModel(message)
        modelContext.insert(model)
        try modelContext.save()
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toConversationMessage() }
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == timelineId })
        try modelContext.save()
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.createdAt < cutoff })
        let matches = try modelContext.fetch(descriptor)
        if !dryRun {
            for model in matches {
                modelContext.delete(model)
            }
            try modelContext.save()
        }
        return matches.count
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let models = try modelContext.fetch(descriptor)
        var snapshots: [TurnSnapshot] = []
        for model in models {
            let message = try model.toConversationMessage()
            guard let data = message.snapshotData else { continue }
            do {
                try snapshots.append(JSONDecoder().decode(TurnSnapshot.self, from: data))
            } catch {
                throw PersistenceError.decoding("TurnSnapshot: \(error)")
            }
        }
        return snapshots
    }
}
