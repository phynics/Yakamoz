import Foundation
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// YAK-47: read-only filesystem tools (`cat`/`ls`/`find`/`search_files`/`grep`) execute
/// without per-call approval. Verified at three levels: the `withoutPermissionRequirement()`
/// decorator, the `YakamozRuntime.resolveTools` wiring (allowlist-based), and an end-to-end
/// scripted `cat` call that confirms no pending approval is surfaced on the bridge while the
/// tool still executes — and that `terminal_run` (a non-allowlisted permissioned tool) keeps
/// its gate.
@Suite("YAK-47: Read-only tool auto-approval")
struct ReadOnlyToolApprovalTests {

    // MARK: - Decorator

    @Test("withoutPermissionRequirement flips the flag and forwards everything else")
    func decoratorFlipsFlagAndForwardsMembers() async throws {
        let base = StubPermissionedTool().toAnyTool()
        let unpermissioned = base.withoutPermissionRequirement()

        #expect(unpermissioned.id == "stub-perm")
        #expect(unpermissioned.name == "Stub Perm")
        #expect(unpermissioned.description == "A stub permissioned tool")
        #expect(unpermissioned.requiresPermission == false)
        #expect(unpermissioned.usageExample == base.usageExample)
        #expect(unpermissioned.parametersSchema == base.parametersSchema)
        #expect(await unpermissioned.canExecute() == true)

        let result = try await unpermissioned.execute(parameters: ["path": "x"])
        #expect(result.success)
        #expect(result.output == "ran:x")

        // Summarize is forwarded (not overridden).
        let summarizeBase = base.summarize(parameters: ["path": "x"], result: result)
        #expect(unpermissioned.summarize(parameters: ["path": "x"], result: result) == summarizeBase)

        // Provenance is preserved through the wrapper.
        #expect(unpermissioned.provenance == base.provenance)
    }

    @Test("Decorator composes with withExplanationParameter preserving schema + flag (both orders)")
    func decoratorComposesWithExplanation() {
        let base = StubPermissionedTool().toAnyTool()

        // Order 1: explanation first, then unpermission (the order resolveTools uses).
        let order1 = base.withExplanationParameter().withoutPermissionRequirement()
        #expect(order1.requiresPermission == false)
        #expect(order1.parametersSchema["properties"]?.asDictionary?[ToolExplanationParameter.key] != nil)

        // Order 2: unpermission first, then explanation.
        let order2 = base.withoutPermissionRequirement().withExplanationParameter()
        #expect(order2.requiresPermission == false)
        #expect(order2.parametersSchema["properties"]?.asDictionary?[ToolExplanationParameter.key] != nil)
    }

    @Test("Allowlist is exactly the read-only filesystem tool ids")
    func allowlistIsExact() {
        #expect(ReadOnlyToolApproval.autoApprovedToolIds == ["cat", "ls", "find", "search_files", "grep"])
    }

    // MARK: - resolveTools wiring

    @MainActor
    @Test("resolveTools auto-approves the read-only filesystem tools")
    func resolveToolsAutoApprovesReadOnlyFilesystemTools() async throws {
        let runtime = try makeRuntime()
        let tools = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let byId = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })

        for id in ReadOnlyToolApproval.autoApprovedToolIds {
            #expect(
                byId[id]?.requiresPermission == false,
                "expected \(id) to be auto-approved (requiresPermission == false)"
            )
        }
        // `change_directory` ships unpermissioned upstream; unaffected.
        #expect(byId["change_directory"]?.requiresPermission == false)
        // Built-in demo tools are unpermissioned and unaffected.
        #expect(byId["calculator"]?.requiresPermission == false)
    }

    @MainActor
    @Test("resolveTools keeps the gate on non-allowlisted permissioned tools (terminal_run)")
    func resolveToolsKeepsGateOnTerminalRun() async throws {
        let runtime = try makeRuntime()
        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let tools = await runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil, terminals: [ctx])
        let terminalRun = try #require(tools.first { $0.id == "terminal_run" })
        #expect(terminalRun.requiresPermission == true)
    }

    // MARK: - Integration

    @MainActor
    @Test("A scripted cat call executes without surfacing a pending approval")
    func catCallExecutesWithoutPendingApproval() async throws {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-e2e-key", account: ProviderSettings.apiKeyAccount)

        let mock = MockLLMService()
        mock.mockClient.nextResponses = ["", "Done reading"]
        mock.mockClient.nextToolCalls = [
            [MockToolCall(
                id: "call_cat",
                name: "cat",
                arguments: #"{"path":"hello.txt","explanation":"Reading the file the user asked about."}"#
            )],
        ]

        // Wire a real MainActorToolApprover so we can assert the bridge is never consulted.
        let approver = MainActorToolApprover()
        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock },
            toolApprovalGate: approver
        )

        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yakamoz-yak47-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try "hello world".data(using: .utf8)!.write(
            to: workspaceURL.appendingPathComponent("hello.txt")
        )

        let conversation = try await runtime.createConversation(
            modelContext: ModelContext(container),
            title: "YAK-47"
        )
        let viewModel = await runtime.makeChatViewModel(
            timelineId: conversation.id,
            enabledToolIds: ["cat"],
            workspaceRoot: workspaceURL
        )

        viewModel.send("read hello.txt")
        await viewModel.awaitSendCompletion()

        // The read-only `cat` call must NOT have surfaced a pending approval on the bridge.
        #expect(
            approver.pending.isEmpty,
            "cat should be auto-approved, but a pending approval was surfaced: \(approver.pending)"
        )

        // The tool actually executed and returned the file content.
        let assistantTurn = try #require(viewModel.transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }.first)
        #expect(assistantTurn.isComplete)
        let trace = try #require(assistantTurn.orderedTools.first)
        #expect(trace.state == .succeeded)
        #expect(trace.output == "hello world")
    }

    // MARK: - Helpers

    @MainActor
    private func makeRuntime() throws -> YakamozRuntime {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let mock = MockLLMService()
        return try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: FakeSecretStore(),
            llmServiceFactory: { _ in mock }
        )
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(YakamozSchema.models)
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    @MainActor
    private func makeSettings() -> ProviderSettings {
        let suiteName = "ReadOnlyToolApprovalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        return settings
    }
}

/// A permissioned stub used to assert the decorator forwards every member except the flag.
private struct StubPermissionedTool: Tool {
    var id: String { "stub-perm" }
    var name: String { "Stub Perm" }
    var description: String { "A stub permissioned tool" }
    var requiresPermission: Bool { true }
    var usageExample: String? { #"{"path": "x"}"# }
    var parametersSchema: [String: AnyCodable] {
        [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["path": ["type": "string"]]),
            "required": AnyCodable(["path"]),
        ]
    }

    func canExecute() async -> Bool { true }

    func execute(parameters: [String: Any]) async throws -> ToolResult {
        let path = parameters["path"] as? String ?? ""
        return .success("ran:\(path)")
    }
}
