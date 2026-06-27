import Foundation
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

struct TerminalToolGatingTests {
    // MARK: - WorkspaceModel.kind

    @Test func workspaceModelDefaultsToFolderKind() {
        let ws = WorkspaceModel(displayName: "w", folderPath: "/tmp")
        #expect(ws.kind == .folder)
    }

    @Test func workspaceModelCanBeTerminalKind() {
        let ws = WorkspaceModel(displayName: "term", folderPath: "/tmp", kind: .terminal)
        #expect(ws.kind == .terminal)
    }

    // MARK: - toolOptions gating

    @Test func terminalOptionsAppearOnlyWhenHasTerminal() {
        let withoutTerminal = ConversationToolSupport.toolOptions(hasWorkspace: false, hasTerminal: false)
        #expect(withoutTerminal.allSatisfy { !$0.requiresTerminal })

        let withTerminal = ConversationToolSupport.toolOptions(hasWorkspace: false, hasTerminal: true)
        let terminalIds = Set(withTerminal.filter { $0.requiresTerminal }.map(\.id))
        #expect(terminalIds == ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"])
    }

    @Test func toolOptionsDefaultsHasTerminalFalse() {
        // The default-parameter form (used by folder-only call sites) excludes terminal options.
        let options = ConversationToolSupport.toolOptions(hasWorkspace: true)
        #expect(options.allSatisfy { !$0.requiresTerminal })
    }

    // MARK: - resolveTools terminal wiring

    @MainActor
    private func makeRuntime() throws -> YakamozRuntime {
        let schema = Schema([
            ConversationModel.self, MessageModel.self, TurnInspectionModel.self,
            PersonaModel.self, WorkspaceModel.self, TimelineModel.self,
            WorkspaceReferenceModel.self, ToolReferenceModel.self,
            AgentInstanceModel.self, AgentTemplateModel.self, RequestOriginModel.self,
        ])
        let container = try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
        let suiteName = "TerminalToolGatingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        let mock = MockLLMService()
        return try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: FakeSecretStore(),
            llmServiceFactory: { _ in mock }
        )
    }

    @MainActor
    @Test func resolveToolsAppendsTerminalToolsOnlyForAttachedTerminals() throws {
        let runtime = try makeRuntime()

        // No terminals → no terminal tools.
        let none = runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil, terminals: [])
        #expect(!none.map(\.id).contains("terminal_run"))

        // One terminal context → its five tools appear.
        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let withTerminal = runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil, terminals: [ctx])
        let ids = Set(withTerminal.map(\.id))
        #expect(ids.isSuperset(of: ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"]))
    }

    @MainActor
    @Test func resolveToolsRespectsEnabledFilterForTerminalTools() throws {
        let runtime = try makeRuntime()
        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let filtered = runtime.resolveTools(
            enabledToolIds: ["terminal_run"],
            workspaceRoot: nil,
            terminals: [ctx]
        )
        let ids = filtered.map(\.id)
        #expect(ids == ["terminal_run"])
    }
}
