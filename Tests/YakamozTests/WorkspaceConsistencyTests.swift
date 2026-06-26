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
}

// MARK: - Test Helpers

private func makeTestModelContainer() throws -> ModelContainer {
    let config = ModelConfiguration(
        schema: Schema(YakamozSchema.models),
        isStoredInMemoryOnly: true
    )
    return try ModelContainer(for: Schema(YakamozSchema.models), configurations: config)
}
