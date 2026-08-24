import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// ATW-5: `resolveTools(enabledToolIds:workspaceRoots:terminals:)` generalizes tool
/// resolution from a single optional folder root to an ordered list of roots, with the
/// operator vault root first. These tests prove the multi-root behavior the production
/// code already implements: no-roots, vault+folder multi-root, vault-first ordering,
/// enabled filtering, and terminal coexistence. Jail-root-specificity is covered in
/// `ToolWorkspaceSecurityTests`.
@MainActor
@Suite("Multi-root tool resolution (ATW-5)")
struct MultiRootToolResolutionTests {
    private func makeRuntime() throws -> YakamozRuntime {
        let container = try makeModelContainer()
        let suiteName = "MultiRootToolResolutionTests.\(UUID().uuidString)"
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

    private func makeTempDir(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ATW5-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private let fileToolIds = Set(["cat", "ls", "find", "search_files", "grep", "change_directory"])

    @Test("no roots yields only non-workspace (built-in) tools")
    func noRootsYieldsOnlyBuiltInTools() async throws {
        let runtime = try makeRuntime()
        let tools = await runtime.resolveTools(enabledToolIds: [], workspaceRoots: [], terminals: [])
        let ids = Set(tools.map(\.callName))
        // Built-ins present.
        #expect(ids.contains("calculator"))
        #expect(ids.contains("current_datetime"))
        // No filesystem or terminal tools.
        #expect(ids.isDisjoint(with: fileToolIds))
        #expect(!ids.contains("terminal_run"))
    }

    @Test("vault plus one folder yields filesystem tools for both roots")
    func vaultPlusFolderYieldsFilesystemToolsForBothRoots() async throws {
        let runtime = try makeRuntime()
        let vault = try makeTempDir("vault")
        let folder = try makeTempDir("folder")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: folder) }

        let tools = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoots: [vault, folder],
            terminals: []
        )
        // Each filesystem tool id appears once per root (two roots → two of each).
        for id in fileToolIds {
            let matches = tools.filter { $0.callName == id }
            #expect(matches.count == 2, "\(id) should appear once per root (got \(matches.count))")
        }
    }

    @Test("the operator vault root's tools come before attached workspaces")
    func vaultRootIsFirstInOrder() async throws {
        let runtime = try makeRuntime()
        let vault = try makeTempDir("vault-root")
        let folder = try makeTempDir("attached-folder")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: folder) }

        let tools = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoots: [vault, folder],
            terminals: []
        )
        let cats = tools.filter { $0.callName == "cat" }
        #expect(cats.count == 2)
        /// The origin name is the root's last path component, so the first cat is the
        /// vault root and the second is the attached folder. (workspaceID is minted per
        /// call, so name — not id — is the stable ordering signal.)
        func workspaceName(_ p: ToolOrigin) -> String? {
            if case let .workspace(_, name) = p { return name }
            return nil
        }
        #expect(workspaceName(cats[0].origin) == vault.lastPathComponent)
        #expect(workspaceName(cats[1].origin) == folder.lastPathComponent)
    }

    @Test("enabled filtering still applies to multi-root filesystem tools")
    func enabledFilteringAppliesToMultiRoot() async throws {
        let runtime = try makeRuntime()
        let vault = try makeTempDir("vault")
        let folder = try makeTempDir("folder")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: folder) }

        let filtered = await runtime.resolveTools(
            enabledToolIds: ["cat"],
            workspaceRoots: [vault, folder],
            terminals: []
        )
        let ids = filtered.map(\.callName)
        // Only `cat` survives (one per root), nothing else.
        #expect(ids.filter { $0 == "cat" }.count == 2)
        #expect(Set(ids).subtracting(["cat"]).isEmpty)
    }

    @Test("empty enabledToolIds returns all tools unfiltered")
    func emptyEnabledReturnsAll() async throws {
        let runtime = try makeRuntime()
        let vault = try makeTempDir("vault")
        defer { try? FileManager.default.removeItem(at: vault) }

        let all = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoots: [vault],
            terminals: []
        )
        let ids = Set(all.map(\.callName))
        #expect(ids.contains("calculator"))
        #expect(ids.contains("cat"))
        #expect(ids.contains("ls"))
    }

    @Test("terminal tools remain available alongside multi-root filesystem tools")
    func terminalToolsCoexistWithMultiRootFilesystem() async throws {
        let runtime = try makeRuntime()
        let vault = try makeTempDir("vault")
        let folder = try makeTempDir("folder")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: folder) }

        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let tools = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoots: [vault, folder],
            terminals: [ctx]
        )
        let ids = Set(tools.map(\.callName))

        // Filesystem tools for both roots.
        #expect(ids.isSuperset(of: ["cat", "ls", "find", "search_files", "grep"]))
        // Terminal tools for the one attached terminal.
        #expect(ids.isSuperset(of: ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"]))
        // And the terminal tool carries the attached terminal's origin.
        #expect(tools.contains { tool in
            tool.callName == "terminal_run" && tool.origin == .terminal(id: ctx.workspaceId, name: "tmp")
        })
    }
}

private func makeModelContainer() throws -> ModelContainer {
    let schema = Schema(YakamozSchema.models)
    return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
}
