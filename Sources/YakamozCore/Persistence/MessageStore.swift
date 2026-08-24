import Foundation
import Logging
import PKContracts
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
    convenience init(_ message: ThreadMessage) throws {
        let messageEnvelopeData: Data?
        do {
            messageEnvelopeData = try JSONEncoder().encode(MessageStoreEnvelope(message: message))
        } catch {
            throw PersistenceError.encoding("ThreadMessage envelope: \(error)")
        }
        self.init(
            id: message.id,
            conversationId: message.threadID,
            role: message.messageRole,
            content: message.content,
            messageEnvelopeData: messageEnvelopeData,
            createdAt: message.timestamp,
            remoteDepth: message.remoteDepth
        )
    }

    func toThreadMessage() throws -> ThreadMessage {
        guard let messageEnvelopeData else {
            return ThreadMessage(
                id: id,
                threadID: conversationId,
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
            throw PersistenceError.decoding("ThreadMessage envelope: \(error)")
        }
        var message = envelope.message
        // The model's scalar columns are authoritative for queryable fields;
        // the envelope carries everything else.
        message.id = id
        message.threadID = conversationId
        message.content = content
        message.timestamp = createdAt
        message.remoteDepth = remoteDepth
        return message
    }
}

/// Wraps the full `ThreadMessage` so non-scalar fields (recalledMemories,
/// parentId, think, toolCalls, toolCallId, agentInstanceId, snapshotData) survive
/// the round trip through `MessageModel.messageEnvelopeData`.
private struct MessageStoreEnvelope: Codable {
    var message: ThreadMessage
}

/// `ThreadMessageStoreProtocol` adapter that confines a SwiftData `ModelContext` to
/// persist `ThreadMessage` values as `MessageModel` rows.
///
/// `ModelContext` is not `Sendable`; `@ModelActor` confines it to this actor so
/// every method can do its `FetchDescriptor`/mapping/save inside the actor and
/// return only `Sendable` PositronicKit values across the boundary.
@ModelActor
public actor SwiftDataMessageStore: ThreadMessageStoreProtocol {
    public nonisolated let isDurable = true

    public func saveMessage(_ message: ThreadMessage) async throws {
        let model = try MessageModel(message)
        modelContext.insert(model)
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save ThreadMessage", metadata: [
                "store": "MessageStore",
                "threadID": "\(message.threadID)",
                "messageID": "\(message.id)",
            ])
            throw error
        }
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == threadID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        do {
            return try modelContext.fetch(descriptor).map { try $0.toThreadMessage() }
        } catch {
            Log.runtime.warning("failed to fetch ThreadMessages", metadata: [
                "store": "MessageStore",
                "threadID": "\(threadID)",
            ])
            throw error
        }
    }

    public func deleteMessages(for threadID: UUID) async throws {
        try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == threadID })
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to delete ThreadMessages", metadata: [
                "store": "MessageStore",
                "threadID": "\(threadID)",
            ])
            throw error
        }
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
                Log.runtime.error("failed to prune ThreadMessages", metadata: [
                    "store": "MessageStore",
                    "count": "\(matches.count)",
                ])
                throw error
            }
        }
        return matches.count
    }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == threadID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let models = try modelContext.fetch(descriptor)
        var snapshots: [TurnSnapshot] = []
        for model in models {
            let message = try model.toThreadMessage()
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
