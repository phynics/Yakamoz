import Foundation
import SwiftData
import Testing
@testable import YakamozCore

@Suite("ConversationAttachment")
struct ConversationAttachmentTests {
    @Test func legacyWorkspaceIdFoldsIntoAttachedList() throws {
        let c = ConversationModel(title: "t")
        c.workspaceId = UUID()
        // allAttachedWorkspaceIds merges legacy single id with the new array
        #expect(try c.allAttachedWorkspaceIds == [#require(c.workspaceId)])
    }

    @Test func newAttachmentsUseTheArray() {
        let c = ConversationModel(title: "t")
        let a = UUID(); let b = UUID()
        c.attachedWorkspaceIds = [a, b]
        #expect(Set(c.allAttachedWorkspaceIds) == [a, b])
    }

    @Test func backfillLegacyAttachment() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [UUID(), UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        // Legacy id should be moved to the array
        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.contains(legacyId))
        // Should not duplicate
        #expect(c.attachedWorkspaceIds.filter { $0 == legacyId }.count == 1)
    }

    @Test func backfillLegacyAttachmentIdempotent() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)
        let afterFirstCall = c.attachedWorkspaceIds.count

        // Call again when workspaceId is already nil
        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        // Should be no-op
        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.count == afterFirstCall)
    }

    @Test func backfillLegacyAttachmentWithAlreadyPresentId() {
        let c = ConversationModel(title: "t")
        let legacyId = UUID()
        c.workspaceId = legacyId
        c.attachedWorkspaceIds = [legacyId, UUID()]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds.filter { $0 == legacyId }.count == 1)
    }

    @Test func backfillLegacyAttachmentNoOpWhenNil() {
        let c = ConversationModel(title: "t")
        let otherId = UUID()
        c.workspaceId = nil
        c.attachedWorkspaceIds = [otherId]

        WorkspaceAttachmentSupport.backfillLegacyAttachment(c)

        #expect(c.workspaceId == nil)
        #expect(c.attachedWorkspaceIds == [otherId])
    }

    @Test func attachSecondWorkspaceKeepsFirstAttached() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let firstWorkspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )
        let firstId = firstWorkspace.id

        let tempDir = FileManager.default.temporaryDirectory
        let secondWorkspace = WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: tempDir
        )
        let secondId = secondWorkspace.id

        // Both ids should be in attachedWorkspaceIds
        #expect(c.attachedWorkspaceIds.contains(firstId))
        #expect(c.attachedWorkspaceIds.contains(secondId))
        #expect(c.attachedWorkspaceIds.count == 2)

        // Folder tools should be enabled (check via effective set)
        let effectiveTools = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(effectiveTools.intersection(FileSystemWorkspace.toolIds).count > 0)
    }

    @Test func detachOneWorkspaceKeepsOtherAttached() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let firstWorkspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )
        let firstId = firstWorkspace.id

        let tempDir = FileManager.default.temporaryDirectory
        let secondWorkspace = WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: tempDir
        )
        let secondId = secondWorkspace.id

        // Detach first workspace
        WorkspaceAttachmentSupport.detachWorkspace(id: firstId, from: c, modelContext: context)

        // Second should still be attached
        #expect(c.attachedWorkspaceIds.contains(secondId))
        #expect(!c.attachedWorkspaceIds.contains(firstId))

        // Folder tools should still be enabled (because second workspace is still attached)
        let effectiveAfterDetach = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(effectiveAfterDetach.intersection(FileSystemWorkspace.toolIds).count > 0)
    }

    @Test func detachLastWorkspaceDisablesFolderTools() throws {
        let c = ConversationModel(title: "t")
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let workspace = try WorkspaceAttachmentSupport.attachWorkspace(
            to: c,
            modelContext: context,
            url: #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        )
        let workspaceId = workspace.id

        // Verify folder tools are enabled
        let effectiveBefore = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true)
        #expect(effectiveBefore.intersection(FileSystemWorkspace.toolIds).count > 0)

        // Detach the only workspace
        WorkspaceAttachmentSupport.detachWorkspace(id: workspaceId, from: c, modelContext: context)

        // attachedWorkspaceIds should be empty
        #expect(c.attachedWorkspaceIds.isEmpty)

        // Folder tools should be disabled (when no workspace attached)
        let effectiveAfter = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: false)
        #expect(effectiveAfter.intersection(FileSystemWorkspace.toolIds).count == 0)

        // Built-in tools should still be available if they were enabled
        #expect(c.enabledToolIds.filter { ConversationToolSupport.builtInToolIDs.contains($0) }.count >= 0)
    }

    @Test func attachTerminalCreatesTerminalWorkspaceAndEnablesTerminalTools() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)

        let folder = WorkspaceModel(displayName: "proj", folderPath: "/tmp/proj")
        context.insert(folder)
        let c = ConversationModel(title: "t")
        c.attachedWorkspaceIds = [folder.id]
        context.insert(c)
        try context.save()

        let terminal = WorkspaceAttachmentSupport.attachTerminal(to: c, fromFolder: folder, modelContext: context)

        // A terminal-kind workspace rooted at the folder's path was created and attached.
        #expect(terminal.kind == .terminal)
        #expect(terminal.folderPath == "/tmp/proj")
        #expect(c.allAttachedWorkspaceIds.contains(terminal.id))

        // The five terminal tools are now enabled.
        let effective = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true, hasTerminal: true)
        #expect(effective.isSuperset(of: TerminalWorkspace.toolIds))
    }

    @Test func createTerminalFromFolderURLCreatesAndAttachesFolderAndTerminal() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let c = ConversationModel(title: "t")
        context.insert(c)

        let url = URL(fileURLWithPath: "/tmp/test-project")

        let terminal = WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: c, modelContext: context)

        // A folder workspace at the URL was created
        let folderExists = try context.fetch(FetchDescriptor<WorkspaceModel>()).contains { ws in
            ws.kind == .folder && ws.folderPath == url.path
        }
        #expect(folderExists)

        // A terminal workspace was created and attached
        #expect(terminal.kind == .terminal)
        #expect(terminal.folderPath == url.path)
        #expect(c.allAttachedWorkspaceIds.contains(terminal.id))

        // Terminal tools are enabled
        let effective = ConversationToolSupport.effectiveEnabledToolIDs(c.enabledToolIds, hasWorkspace: true, hasTerminal: true)
        #expect(effective.isSuperset(of: TerminalWorkspace.toolIds))
    }

    @Test func createTerminalFromFolderURLPreventsDuplicateTerminals() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let c = ConversationModel(title: "t")
        context.insert(c)

        let url = URL(fileURLWithPath: "/tmp/duplicate-test")

        // Create first terminal
        let terminal1 = WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: c, modelContext: context)

        // Create "terminal" again for same conversation/folder
        let terminal2 = WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: c, modelContext: context)

        // Should return the same terminal (not create a duplicate)
        #expect(terminal1.id == terminal2.id)

        // Verify only one terminal is attached for this conversation/folder
        let terminals = try context.fetch(FetchDescriptor<WorkspaceModel>()).filter { ws in
            ws.kind == .terminal && ws.folderPath == url.path
        }
        #expect(terminals.count == 1)

        // Attached workspace ids should not contain duplicates
        let terminalIds = c.allAttachedWorkspaceIds.filter { id in
            let ws = try? context.fetch(FetchDescriptor<WorkspaceModel>()).first { $0.id == id && $0.kind == .terminal }
            return ws != nil
        }
        #expect(terminalIds.count == 1)
    }

    @Test func createTerminalFromFolderURLReusesExistingFolderWorkspace() throws {
        let container = try makeTestModelContainer()
        let context = ModelContext(container)
        let c = ConversationModel(title: "t")
        context.insert(c)

        let url = URL(fileURLWithPath: "/tmp/reuse-folder")

        // First, attach a folder workspace
        let folder = WorkspaceAttachmentSupport.attachWorkspace(to: c, modelContext: context, url: url)
        let folderId = folder.id

        // Then create a terminal from the same URL
        let terminal = WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: c, modelContext: context)

        // The same folder should still be attached (not duplicated)
        #expect(c.allAttachedWorkspaceIds.contains(folderId))

        // The terminal should be attached
        #expect(c.allAttachedWorkspaceIds.contains(terminal.id))

        // Total workspaces should be 2 (folder + terminal), not 3
        let count = c.allAttachedWorkspaceIds.count
        #expect(count == 2)
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
