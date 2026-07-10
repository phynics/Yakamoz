import JSONSchema
import JSONSchemaBuilder
import PKShared

public enum ToolExplanationParameter {
    public static let key = "explanation"
    public static let description = "One short sentence, user-facing, explaining why you are calling this tool right now."
}

public extension AnyTool {
    func withExplanationParameter() -> AnyTool {
        guard parametersSchema.asDictionary["properties"]?.asDictionary?[ToolExplanationParameter.key] == nil else {
            assertionFailure("Yakamoz tool '\(callName)' declares reserved parameter '\(ToolExplanationParameter.key)'")
            return self
        }
        return AnyTool(ExplainedTool(wrapped: self), provenance: provenance)
    }
}

private struct ExplainedTool: Tool {
    let wrapped: AnyTool

    var callName: String { wrapped.callName }
    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var requiresPermission: Bool { wrapped.requiresPermission }
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
