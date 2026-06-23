import Foundation
import PKShared
import PositronicKit
import SwiftData

extension WorkspaceReferenceModel {
    convenience init(_ workspace: WorkspaceReference) throws {
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(workspace.metadata)
        } catch {
            throw PersistenceError.encoding("WorkspaceReference.metadata: \(error)")
        }
        self.init(
            id: workspace.id,
            uriHost: workspace.uri.host,
            uriPath: workspace.uri.path,
            locationRaw: workspace.location.rawValue,
            originId: workspace.originId,
            rootPath: workspace.rootPath,
            trustLevelRaw: workspace.trustLevel.rawValue,
            lastModifiedBy: workspace.lastModifiedBy,
            statusRaw: workspace.status.rawValue,
            metadataData: metadataData,
            contextInjection: workspace.contextInjection,
            createdAt: workspace.createdAt
        )
    }

    /// Reconstructs the `WorkspaceReference`, attaching `tools` (fetched separately
    /// by the caller, since tools live in their own `ToolReferenceModel` rows).
    func toWorkspaceReference(tools: [ToolReference]) throws -> WorkspaceReference {
        guard let location = WorkspaceReference.WorkspaceLocation(rawValue: locationRaw) else {
            throw PersistenceError.decoding("Unknown WorkspaceLocation raw value: \(locationRaw)")
        }
        guard let trustLevel = WorkspaceTrustLevel(rawValue: trustLevelRaw) else {
            throw PersistenceError.decoding("Unknown WorkspaceTrustLevel raw value: \(trustLevelRaw)")
        }
        guard let status = WorkspaceReference.WorkspaceStatus(rawValue: statusRaw) else {
            throw PersistenceError.decoding("Unknown WorkspaceStatus raw value: \(statusRaw)")
        }
        let metadata: [String: AnyCodable]
        do {
            metadata = try JSONDecoder().decode([String: AnyCodable].self, from: metadataData)
        } catch {
            throw PersistenceError.decoding("WorkspaceReference.metadata: \(error)")
        }
        return WorkspaceReference(
            id: id,
            uri: WorkspaceURI(host: uriHost, path: uriPath),
            location: location,
            originId: originId,
            tools: tools,
            rootPath: rootPath,
            trustLevel: trustLevel,
            lastModifiedBy: lastModifiedBy,
            status: status,
            metadata: metadata,
            contextInjection: contextInjection,
            createdAt: createdAt
        )
    }

    func update(from workspace: WorkspaceReference) throws {
        let encodedMetadata: Data
        do {
            encodedMetadata = try JSONEncoder().encode(workspace.metadata)
        } catch {
            throw PersistenceError.encoding("WorkspaceReference.metadata: \(error)")
        }
        uriHost = workspace.uri.host
        uriPath = workspace.uri.path
        locationRaw = workspace.location.rawValue
        originId = workspace.originId
        rootPath = workspace.rootPath
        trustLevelRaw = workspace.trustLevel.rawValue
        lastModifiedBy = workspace.lastModifiedBy
        statusRaw = workspace.status.rawValue
        metadataData = encodedMetadata
        contextInjection = workspace.contextInjection
        createdAt = workspace.createdAt
    }
}

/// `WorkspacePersistenceProtocol` adapter persisting `WorkspaceReference` values
/// as `WorkspaceReferenceModel` rows, with nested `tools` stored separately as
/// `ToolReferenceModel` rows keyed by `workspaceId` (mirrors how `ToolPersistenceProtocol`
/// addresses tools independently of workspace saves).
@ModelActor
public actor SwiftDataWorkspaceStore: WorkspacePersistenceProtocol {
    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        let id = workspace.id
        let descriptor = FetchDescriptor<WorkspaceReferenceModel>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.update(from: workspace)
        } else {
            try modelContext.insert(WorkspaceReferenceModel(workspace))
        }
        try modelContext.save()

        // Replace the workspace's tool rows with the set carried on the value.
        try modelContext.delete(model: ToolReferenceModel.self, where: #Predicate { $0.workspaceId == id })
        for tool in workspace.tools {
            try modelContext.insert(ToolReferenceModel(workspaceId: id, tool: tool))
        }
        try modelContext.save()
    }

    public func fetchWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference? {
        var descriptor = FetchDescriptor<WorkspaceReferenceModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        let tools = includeTools ? try fetchToolReferences(workspaceIds: [id]) : []
        return try model.toWorkspaceReference(tools: tools)
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        let descriptor = FetchDescriptor<WorkspaceReferenceModel>(sortBy: [SortDescriptor(\.createdAt)])
        let models = try modelContext.fetch(descriptor)
        return try models.map { model in
            let tools = try fetchToolReferences(workspaceIds: [model.id])
            return try model.toWorkspaceReference(tools: tools)
        }
    }

    public func deleteWorkspace(id: UUID) async throws {
        try modelContext.delete(model: WorkspaceReferenceModel.self, where: #Predicate { $0.id == id })
        try modelContext.delete(model: ToolReferenceModel.self, where: #Predicate { $0.workspaceId == id })
        try modelContext.save()
    }

    private func fetchToolReferences(workspaceIds: [UUID]) throws -> [ToolReference] {
        let descriptor = FetchDescriptor<ToolReferenceModel>(
            predicate: #Predicate { workspaceIds.contains($0.workspaceId) }
        )
        return try modelContext.fetch(descriptor).map { try $0.toToolReference() }
    }
}
