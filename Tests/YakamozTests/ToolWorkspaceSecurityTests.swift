import Foundation
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// YAK-33: Validates that the explicit workspaceID security fix in PositronicKit
/// doesn't break existing Yakamoz tool call routing. The unit tests in PositronicKitTests
/// cover the core security invariant directly.
@Suite("ToolWorkspaceSecurity")
@MainActor
struct ToolWorkspaceSecurityTests {
    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(YakamozSchema.models)
        return try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> ProviderSettings {
        let suiteName = "ToolWorkspaceSecurityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        return settings
    }

    @Test("YAK-33: Calculator tool still executes when no workspaceID is specified (regression guard)")
    func calculatorExecutesWithoutWorkspaceID() async throws {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-e2e-key", account: ProviderSettings.apiKeyAccount)

        let mock = MockLLMService()
        mock.mockClient.nextResponses = ["", "The answer is 4"]
        mock.mockClient.nextToolCalls = [
            [MockToolCall(
                id: "call_calc",
                name: "calculator",
                arguments: "{\"expression\": \"2 + 2\"}"
            )],
        ]

        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock }
        )
        let agentID = try #require(try container.mainContext.fetch(FetchDescriptor<AgentModel>()).first?.id)

        let conversation = try await runtime.createConversation(
            modelContext: ModelContext(container),
            title: "YAK-33-regression", agentId: agentID
        )
        let timelineId = conversation.id

        let viewModel = await runtime.makeChatViewModel(
            timelineId: timelineId,
            enabledToolIds: ["calculator"]
        )

        viewModel.send("calculate 2+2")
        // Await the turn's real completion signal (the spawned consume Task finishing)
        // instead of polling isSending against a wall-clock deadline, which could flake
        // under CPU contention (YAK-44). The assistant turn is isComplete by the time
        // consume's defer flips isSending to false.
        await viewModel.awaitSendCompletion()

        let assistantTurn = try #require(viewModel.transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn }
            return nil
        }.first)

        #expect(assistantTurn.isComplete)

        let toolTrace = try #require(assistantTurn.orderedTools.first)
        #expect(toolTrace.name.localizedCaseInsensitiveContains("calc"))
        #expect(toolTrace.state == .succeeded)
        #expect(toolTrace.output == "4")
    }

    /// ATW-5: with multiple roots resolved, a filesystem tool jailed to one root must not
    /// be able to read a file under a sibling root. This proves the "jail roots remain
    /// root-specific" acceptance criterion: each root's `cat` refuses a path that resolves
    /// outside its own jail.
    @Test("ATW-5: a jail root's cat cannot read a sibling root's file")
    func jailRootsRemainRootSpecific() async throws {
        let container = try makeModelContainer()
        let settings = makeSettings()
        let secrets = FakeSecretStore()
        try secrets.write("sk-jail-key", account: ProviderSettings.apiKeyAccount)
        let mock = MockLLMService()
        let runtime = try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: secrets,
            llmServiceFactory: { _ in mock }
        )

        let rootA = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ATW5-jail-A-\(UUID().uuidString)", isDirectory: true)
        let rootB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ATW5-jail-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }

        let secretA = "A-secret"
        let secretB = "B-secret"
        try secretA.write(to: rootA.appendingPathComponent("secretA.txt"), atomically: true, encoding: .utf8)
        try secretB.write(to: rootB.appendingPathComponent("secretB.txt"), atomically: true, encoding: .utf8)

        let tools = await runtime.resolveTools(
            enabledToolIds: [],
            workspaceRoots: [rootA, rootB],
            terminals: []
        )
        /// Find each root's cat tool by its provenance name (root last path component).
        func cat(forRoot root: URL) throws -> AnyTool {
            try #require(tools.first { tool in
                tool.callName == "cat" && {
                    if case let .workspace(_, name) = tool.provenance { return name == root.lastPathComponent }
                    return false
                }()
            })
        }
        let catA = try cat(forRoot: rootA)
        let catB = try cat(forRoot: rootB)

        // Positive control: each cat reads its own root's file.
        let ownA = try await catA.execute(parameters: ["path": AnyCodable("secretA.txt")])
        #expect(ownA.success)
        #expect(ownA.output == secretA)

        // Escape attempt: catA reaches into rootB via a relative traversal.
        let traversal = "../\(rootB.lastPathComponent)/secretB.txt"
        let escapeFromA = try await catA.execute(parameters: ["path": AnyCodable(traversal)])
        #expect(!escapeFromA.success)
        #expect(escapeFromA.output != secretB)

        // Escape attempt: catB reaches into rootA via a relative traversal.
        let escapeFromB = try await catB.execute(parameters: ["path": AnyCodable("../\(rootA.lastPathComponent)/secretA.txt")])
        #expect(!escapeFromB.success)
        #expect(escapeFromB.output != secretA)
    }
}
