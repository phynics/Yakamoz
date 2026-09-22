import JSONSchema
import JSONSchemaBuilder
import Logging
import PKContracts

public enum ToolExplanationParameter {
    public static let key = "explanation"
    public static let description = "One short sentence, user-facing, explaining why you are calling this tool right now."
}

public extension AnyTool {
    func withExplanationParameter() -> AnyTool {
        guard parametersSchema.asDictionary["properties"]?.asDictionary?[ToolExplanationParameter.key] == nil else {
            // Leave the tool's own `explanation` in place; logging (not asserting) keeps
            // this documented skip path reachable in Debug builds and tests.
            Log.runtime.warning("tool declares reserved parameter; skipping explanation decoration", metadata: [
                "tool": "\(callName)",
                "parameter": "\(ToolExplanationParameter.key)",
            ])
            return self
        }
        return AnyTool(ExplainedTool(wrapped: self), origin: origin)
    }
}

private struct ExplainedTool: PKTool {
    let wrapped: AnyTool

    var callName: String { wrapped.callName }
    var identity: ToolReference { wrapped.identity }
    var name: String { wrapped.name }
    var toolDescription: String { wrapped.toolDescription }
    var requiresPermission: Bool { wrapped.requiresPermission }
    var sideEffects: ToolSideEffects { wrapped.sideEffects }

    func requiresPermission(for parameters: [String: AnyCodable]) -> Bool {
        wrapped.requiresPermission(for: parameters)
    }
    var usageExample: String? { wrapped.usageExample }

    var parametersSchema: Schema {
        var schema = wrapped.parametersSchema.asDictionary
        var properties = schema["properties"]?.asDictionary ?? [:]
        properties[ToolExplanationParameter.key] = .dictionary([
            "type": .string("string"),
            "description": .string(ToolExplanationParameter.description),
        ])
        schema["properties"] = .dictionary(properties)
        return Schema(schema)
    }

    func canExecute() async -> Bool {
        await wrapped.canExecute()
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        try await wrapped.execute(parameters: parameters)
    }

    func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String {
        wrapped.summarize(parameters: parameters, result: result)
    }
}
