import Foundation
import SwiftData
import Testing
@testable import YakamozCore

@Suite("ConversationToolSupport")
@MainActor
struct ConversationToolSupportTests {
    @Test("Empty stored ids mean all currently available tools")
    func emptyMeansAllAvailableTools() {
        #expect(
            ConversationToolSupport.effectiveEnabledToolIDs([], hasWorkspace: false) ==
            Set(ConversationToolSupport.builtInToolIDs)
        )
        #expect(
            ConversationToolSupport.effectiveEnabledToolIDs([], hasWorkspace: true) ==
            Set(ConversationToolSupport.toolOptions(hasWorkspace: true).map(\.id))
        )
    }

    @Test("Persisting a full selection collapses back to empty storage")
    func allSelectedCollapsesToEmptyStorage() {
        let allBuiltIns = Set(ConversationToolSupport.builtInToolIDs)
        #expect(ConversationToolSupport.persistedEnabledToolIDs(allBuiltIns, hasWorkspace: false).isEmpty)

        let allWorkspaceTools = Set(ConversationToolSupport.toolOptions(hasWorkspace: true).map(\.id))
        #expect(ConversationToolSupport.persistedEnabledToolIDs(allWorkspaceTools, hasWorkspace: true).isEmpty)
    }

    @Test("Attaching a workspace preserves built-in selection and enables workspace tools")
    func attachWorkspacePreservesAndExpandsSelection() throws {
        let container = try makeModelContainer()
        let modelContext = container.mainContext
        let conversation = ConversationModel(title: "Test", enabledToolIds: ["calculator"])

        let url = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)

        let effective = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: true)
        #expect(conversation.workspaceId != nil)
        #expect(effective.contains("calculator"))
        #expect(!effective.contains("current_datetime"))
        #expect(Set(FileSystemWorkspace.toolIds).isSubset(of: effective))
    }

    @Test("Detaching a workspace removes filesystem tools and keeps built-in choices")
    func detachWorkspaceRemovesWorkspaceTools() throws {
        let container = try makeModelContainer()
        let modelContext = container.mainContext
        let conversation = ConversationModel(title: "Test", enabledToolIds: ["calculator"])

        let url = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
        WorkspaceAttachmentSupport.detachWorkspace(from: conversation, modelContext: modelContext)

        #expect(conversation.workspaceId == nil)
        #expect(conversation.enabledToolIds == ["calculator"])
    }

    @Test("Default all-tools selection stays default across attach and detach")
    func allToolsDefaultStaysImplicit() throws {
        let container = try makeModelContainer()
        let modelContext = container.mainContext
        let conversation = ConversationModel(title: "Test")

        let url = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
        #expect(conversation.enabledToolIds.isEmpty)

        WorkspaceAttachmentSupport.detachWorkspace(from: conversation, modelContext: modelContext)
        #expect(conversation.enabledToolIds.isEmpty)
    }

    private func makeModelContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(YakamozSchema.models),
            configurations: .init(isStoredInMemoryOnly: true)
        )
    }

    private func makeTempRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConversationToolSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath()
    }
}
