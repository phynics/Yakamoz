import Foundation
import PKShared
import PKTestSupport
import SwiftData
import Testing
@testable import YakamozCore

@Suite("Tool explanation decorator")
struct ToolExplanationDecoratorTests {
    @Test("Decorated calculator schema includes optional explanation")
    func decoratedCalculatorSchemaIncludesExplanation() throws {
        let tool = CalculatorTool().toAnyTool().withExplanationParameter()
        let properties = try #require(tool.parametersSchema["properties"]?.asDictionary)

        #expect(properties["expression"] != nil)
        #expect(properties["explanation"]?.asDictionary?["type"]?.asString == "string")
        #expect(properties["explanation"]?.asDictionary?["description"]?.asString == ToolExplanationParameter.description)
        #expect(tool.parametersSchema["required"]?.asArray?.contains(AnyCodable("explanation")) != true)
        #expect(tool.id == "calculator")
        #expect(tool.name == "Calculator")
        #expect(tool.requiresPermission == false)
    }

    @Test("Decorator skips tools that already reserve explanation")
    func skipsExistingExplanationProperty() {
        let base = StubTool(
            parametersSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "explanation": [
                        "type": "string",
                        "description": "existing",
                    ],
                ]),
            ]
        ).toAnyTool()

        let wrapped = base.withExplanationParameter()

        #expect(wrapped.parametersSchema == base.parametersSchema)
    }

    @MainActor
    @Test("Runtime-resolved tools are decorated at the single registration seam")
    func runtimeResolveToolsDecoratesAvailableTools() async throws {
        let runtime = try makeRuntime()

        let tools = await runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil as URL?)

        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { tool in
            tool.parametersSchema["properties"]?.asDictionary?[ToolExplanationParameter.key] != nil
        })
        #expect(tools.allSatisfy { tool in
            tool.parametersSchema["required"]?.asArray?.contains(AnyCodable(ToolExplanationParameter.key)) != true
        })
    }

    @Test("Tool execution receives explanation as a pass-through argument")
    func executionReceivesExplanationArgument() async throws {
        let tool = RecordingTool().toAnyTool().withExplanationParameter()

        let result = try await tool.execute(parameters: [
            "value": "payload",
            "explanation": "Need this value for context.",
        ])

        #expect(result.success)
        #expect(result.output == "payload|Need this value for context.")
    }
}

@MainActor
private func makeRuntime() throws -> YakamozRuntime {
    let schema = Schema(YakamozSchema.models)
    let container = try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
    let suiteName = "ToolExplanationDecoratorTests.\(UUID().uuidString)"
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

private struct StubTool: Tool {
    let parametersSchema: [String: AnyCodable]

    var id: String { "stub" }
    var name: String { "Stub" }
    var description: String { "Stub tool" }
    var requiresPermission: Bool { false }

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters: [String: Any]) async throws -> ToolResult {
        .success("")
    }
}

private struct RecordingTool: Tool {
    var id: String { "recording" }
    var name: String { "Recording" }
    var description: String { "Records arguments" }
    var requiresPermission: Bool { false }
    var parametersSchema: [String: AnyCodable] {
        [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "value": [
                    "type": "string",
                ],
            ]),
            "required": AnyCodable(["value"]),
        ]
    }

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters: [String: Any]) async throws -> ToolResult {
        let value = parameters["value"] as? String ?? ""
        let explanation = parameters[ToolExplanationParameter.key] as? String ?? ""
        return .success("\(value)|\(explanation)")
    }
}
