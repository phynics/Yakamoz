import Foundation
import Logging
import PKShared
import PositronicKit
import SwiftData

extension ToolReferenceModel {
    convenience init(workspaceId: UUID, tool: ToolReference) throws {
        let referenceData: Data
        do {
            referenceData = try JSONEncoder().encode(tool)
        } catch {
            throw PersistenceError.encoding("ToolReference: \(error)")
        }
        self.init(workspaceId: workspaceId, toolId: tool.toolId, referenceData: referenceData)
    }

    func toToolReference() throws -> ToolReference {
        do {
            return try JSONDecoder().decode(ToolReference.self, from: referenceData)
        } catch {
            throw PersistenceError.decoding("ToolReference: \(error)")
        }
    }
}

extension RequestOriginModel {
    convenience init(_ origin: RequestOriginIdentity) {
        self.init(
            id: origin.id,
            hostname: origin.hostname,
            displayName: origin.displayName,
            platform: origin.platform,
            registeredAt: origin.registeredAt,
            lastSeenAt: origin.lastSeenAt
        )
    }

    func toRequestOriginIdentity() -> RequestOriginIdentity {
        RequestOriginIdentity(
            id: id,
            hostname: hostname,
            displayName: displayName,
            platform: platform,
            registeredAt: registeredAt,
            lastSeenAt: lastSeenAt
        )
    }

    func update(from origin: RequestOriginIdentity) {
        hostname = origin.hostname
        displayName = origin.displayName
        platform = origin.platform
        registeredAt = origin.registeredAt
        lastSeenAt = origin.lastSeenAt
    }
}

/// `ToolPersistenceProtocol` adapter persisting `ToolReference` values as
/// `ToolReferenceModel` rows keyed by `(workspaceId, toolId)`.
///
/// Origin-hosted tools (`fetchOriginTools`) are resolved by finding the workspace(s)
/// attributed to the origin via `WorkspaceReferenceModel.originId`, then fetching
/// their tool rows — there is no separate origin-to-tool table.
@ModelActor
public actor SwiftDataToolStore: ToolPersistenceProtocol {
    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        let toolId = tool.toolId
        let compositeId = "\(workspaceId.uuidString):\(toolId)"
        let descriptor = FetchDescriptor<ToolReferenceModel>(predicate: #Predicate { $0.id == compositeId })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.referenceData = try JSONEncoder().encode(tool)
        } else {
            try modelContext.insert(ToolReferenceModel(workspaceId: workspaceId, tool: tool))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to add tool to workspace", metadata: [
                "store": "ToolStore",
                "workspaceID": "\(workspaceId)",
                "toolID": .string(toolId),
            ])
            throw error
        }
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        try modelContext.delete(model: ToolReferenceModel.self, where: #Predicate { $0.workspaceId == workspaceId })
        for tool in tools {
            try modelContext.insert(ToolReferenceModel(workspaceId: workspaceId, tool: tool))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to sync tools", metadata: [
                "store": "ToolStore",
                "workspaceID": "\(workspaceId)",
                "count": "\(tools.count)",
            ])
            throw error
        }
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        let descriptor = FetchDescriptor<ToolReferenceModel>(
            predicate: #Predicate { workspaceIds.contains($0.workspaceId) }
        )
        do {
            return try modelContext.fetch(descriptor).map { try $0.toToolReference() }
        } catch {
            Log.runtime.warning("failed to fetch tools", metadata: [
                "store": "ToolStore",
                "workspaceCount": "\(workspaceIds.count)",
            ])
            throw error
        }
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        let workspaceDescriptor = FetchDescriptor<WorkspaceReferenceModel>(
            predicate: #Predicate { $0.originId == originId }
        )
        let workspaceIds = try modelContext.fetch(workspaceDescriptor).map(\.id)
        guard !workspaceIds.isEmpty else { return [] }
        let toolDescriptor = FetchDescriptor<ToolReferenceModel>(
            predicate: #Predicate { workspaceIds.contains($0.workspaceId) }
        )
        do {
            return try modelContext.fetch(toolDescriptor).map { try $0.toToolReference() }
        } catch {
            Log.runtime.warning("failed to fetch origin tools", metadata: [
                "store": "ToolStore",
                "originID": "\(originId)",
            ])
            throw error
        }
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        var descriptor = FetchDescriptor<ToolReferenceModel>(
            predicate: #Predicate { $0.toolId == toolId && workspaceIds.contains($0.workspaceId) }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first?.workspaceId
        } catch {
            Log.runtime.warning("failed to find workspace for tool", metadata: [
                "store": "ToolStore",
                "toolID": .string(toolId),
            ])
            throw error
        }
    }

    public func fetchToolSource(
        toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?
    ) async throws -> String? {
        if let primaryWorkspaceId {
            let primaryCompositeId = "\(primaryWorkspaceId.uuidString):\(toolId)"
            var primaryDescriptor = FetchDescriptor<ToolReferenceModel>(
                predicate: #Predicate { $0.id == primaryCompositeId }
            )
            primaryDescriptor.fetchLimit = 1
            if try modelContext.fetch(primaryDescriptor).first != nil {
                return primaryWorkspaceId.uuidString
            }
        }
        return try await findWorkspaceId(forToolId: toolId, in: workspaceIds)?.uuidString
    }
}

/// `RequestOriginStoreProtocol` adapter persisting `RequestOriginIdentity` values
/// as `RequestOriginModel` rows.
@ModelActor
public actor SwiftDataRequestOriginStore: RequestOriginStoreProtocol {
    public func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        let id = origin.id
        let descriptor = FetchDescriptor<RequestOriginModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: origin)
        } else {
            modelContext.insert(RequestOriginModel(origin))
        }
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to save RequestOrigin", metadata: [
                "store": "RequestOriginStore",
                "originID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        var descriptor = FetchDescriptor<RequestOriginModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first?.toRequestOriginIdentity()
        } catch {
            Log.runtime.warning("failed to fetch RequestOrigin", metadata: [
                "store": "RequestOriginStore",
                "originID": "\(id)",
            ])
            throw error
        }
    }

    public func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        let descriptor = FetchDescriptor<RequestOriginModel>(sortBy: [SortDescriptor(\.registeredAt)])
        do {
            return try modelContext.fetch(descriptor).map { $0.toRequestOriginIdentity() }
        } catch {
            Log.runtime.warning("failed to fetch all RequestOrigins", metadata: [
                "store": "RequestOriginStore",
            ])
            throw error
        }
    }

    public func deleteOrigin(id: UUID) async throws -> Bool {
        var descriptor = FetchDescriptor<RequestOriginModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return false }
        modelContext.delete(model)
        do {
            try modelContext.save()
        } catch {
            Log.runtime.error("failed to delete RequestOrigin", metadata: [
                "store": "RequestOriginStore",
                "originID": "\(id)",
            ])
            throw error
        }
        return true
    }
}
