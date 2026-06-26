import Foundation
import SwiftData
import Testing
@testable import YakamozCore

struct WorkspaceConsistencyTests {
    @Test func detachingOnlyFolderWorkspaceRemovesFolderTools() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let workspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )

        WorkspaceAttachmentSupport.detachWorkspace(id: workspace.id, from: c, modelContext: context)

        // Invariant: no folder tool ids remain in enabledToolIds once no folder workspace is attached.
        #expect(Set(c.enabledToolIds).intersection(FileSystemWorkspace.toolIds).isEmpty)

        let effectiveAfter = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: false)
        #expect(effectiveAfter.intersection(FileSystemWorkspace.toolIds).isEmpty)
    }

    @Test func detachingOneOfTwoFolderWorkspacesKeepsFolderToolsEnabled() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let firstWorkspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )
        let secondWorkspace = WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: FileManager.default.temporaryDirectory
        )

        WorkspaceAttachmentSupport.detachWorkspace(id: firstWorkspace.id, from: c, modelContext: context)

        #expect(c.attachedWorkspaceIds.contains(secondWorkspace.id))
        let effectiveAfter = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(!effectiveAfter.intersection(FileSystemWorkspace.toolIds).isEmpty)
    }

    @Test func detachingMultiAttachIdKeepsFolderToolsWhenLegacyIdStillAttached() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        // Workspace A: attached via the multi-attach array.
        let workspaceA = WorkspaceModel(displayName: "A", folderPath: "/tmp/a", bookmarkData: nil)
        // Workspace B: attached only via the legacy single-attach field, and does NOT match A.
        let workspaceB = WorkspaceModel(displayName: "B", folderPath: "/tmp/b", bookmarkData: nil)
        context.insert(workspaceA)
        context.insert(workspaceB)

        c.attachedWorkspaceIds = [workspaceA.id]
        c.workspaceId = workspaceB.id
        c.enabledToolIds = ConversationToolSupport.builtInToolIDs + Array(FileSystemWorkspace.toolIds)

        WorkspaceAttachmentSupport.detachWorkspace(id: workspaceA.id, from: c, modelContext: context)

        // attachedWorkspaceIds is now empty, but workspaceB is still logically attached via the
        // legacy `workspaceId` field, so folder tools must remain enabled.
        #expect(c.attachedWorkspaceIds.isEmpty)
        #expect(c.workspaceId == workspaceB.id)
        let effectiveAfter = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(!effectiveAfter.intersection(FileSystemWorkspace.toolIds).isEmpty)
    }

    @Test func reconcileEnabledToolsDirectlyEnforcesInvariant() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        // Seed enabledToolIds with folder tool ids even though no workspace is attached,
        // simulating a stale/inconsistent state.
        c.enabledToolIds = ConversationToolSupport.builtInToolIDs + Array(FileSystemWorkspace.toolIds)

        WorkspaceAttachmentSupport.reconcileEnabledTools(for: c, attachedWorkspaces: [])

        #expect(Set(c.enabledToolIds).intersection(FileSystemWorkspace.toolIds).isEmpty)

        // Now reconcile with a workspace attached; folder tools should be allowed again.
        let workspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )
        WorkspaceAttachmentSupport.reconcileEnabledTools(for: c, attachedWorkspaces: [workspace])
        let effective = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(!effective.intersection(FileSystemWorkspace.toolIds).isEmpty)
    }

    @Test func pruneOrphanWorkspacesDeletesUnreferencedKeepsReferenced() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let referenced = WorkspaceModel(displayName: "Referenced", folderPath: "/tmp/referenced", bookmarkData: nil)
        let orphaned = WorkspaceModel(displayName: "Orphaned", folderPath: "/tmp/orphaned", bookmarkData: nil)
        context.insert(referenced)
        context.insert(orphaned)

        let c = ConversationModel(title: "t")
        c.attachedWorkspaceIds = [referenced.id]
        context.insert(c)
        try context.save()

        WorkspaceAttachmentSupport.pruneOrphanWorkspaces(modelContext: context)

        let remaining = try context.fetch(FetchDescriptor<WorkspaceModel>())
        let remainingIds = Set(remaining.map(\.id))
        #expect(remainingIds.contains(referenced.id))
        #expect(!remainingIds.contains(orphaned.id))
    }

    @Test func pruneOrphanWorkspacesKeepsLegacyOnlyReferencedWorkspace() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let legacyReferenced = WorkspaceModel(displayName: "Legacy", folderPath: "/tmp/legacy", bookmarkData: nil)
        context.insert(legacyReferenced)

        let c = ConversationModel(title: "t")
        c.workspaceId = legacyReferenced.id
        context.insert(c)
        try context.save()

        WorkspaceAttachmentSupport.pruneOrphanWorkspaces(modelContext: context)

        let remaining = try context.fetch(FetchDescriptor<WorkspaceModel>())
        let remainingIds = Set(remaining.map(\.id))
        #expect(remainingIds.contains(legacyReferenced.id))
    }
}

// MARK: - Test Helpers

private func makeTestModelContainer() throws -> ModelContainer {
    let config = ModelConfiguration(
        schema: Schema(YakamozSchema.models),
        isStoredInMemoryOnly: true
    )
    return try ModelContainer(for: Schema(YakamozSchema.models), configurations: config)
}
