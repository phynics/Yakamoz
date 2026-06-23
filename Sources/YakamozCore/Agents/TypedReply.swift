import Foundation
import JSONSchemaBuilder
import PKShared

/// The one concrete structured-reply shape Yakamoz supports: a short summary plus a
/// flat list of action items. `@Schemable` derives the JSON Schema used to request the
/// reply from the provider and to validate/decode the model's final response.
@Schemable
public struct TypedReplyPayload: Codable, Sendable, Equatable {
    public let summary: String
    public let actionItems: [String]

    public init(summary: String, actionItems: [String]) {
        self.summary = summary
        self.actionItems = actionItems
    }
}

/// Builds and validates the typed-reply structured-output contract.
///
/// `TypedReply` owns the typed-reply schema and the inspection-time decode path.
/// The live turn now sends the schema through `PositronicKit.run(..., structuredOutput:)`,
/// while the response inspector still persists the schema JSON and decodes the final
/// reconstructed text with `StructuredOutputDecoder` so the Response tab can show the
/// parsed JSON or validation error. See `TypedReply.decode(from:)`.
public enum TypedReply {
    public static let schemaName = "yakamoz_typed_reply"

    /// The structured-output schema describing `TypedReplyPayload`.
    public static func schema() -> StructuredOutputSchema {
        StructuredOutputSchema(
            name: schemaName,
            description: "A concise summary plus a flat list of concrete action items.",
            schema: TypedReplyPayload.schema.definition()
        )
    }

    /// The structured-output request (JSON-schema mode) for the typed reply.
    public static func request() -> StructuredOutputRequest {
        .jsonSchema(schema())
    }

    /// Pretty-printed JSON of the schema, for the Response inspector tab.
    public static func schemaJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(schema().schema) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes and re-encodes a model response as a validated `TypedReplyPayload`.
    ///
    /// Returns the parsed payload plus its canonical pretty-printed JSON on success, or a
    /// `StructuredOutputDecodingError` (surfaced as a human string) on failure. Empty input
    /// (e.g. a cancelled turn that produced no text) is treated as "no structured reply",
    /// returning `nil` for both fields rather than a validation error.
    public struct DecodeResult: Sendable, Equatable {
        public let payload: TypedReplyPayload?
        public let parsedJSON: String?
        public let error: String?

        public init(payload: TypedReplyPayload?, parsedJSON: String?, error: String?) {
            self.payload = payload
            self.parsedJSON = parsedJSON
            self.error = error
        }
    }

    public static func decode(from response: String) -> DecodeResult {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DecodeResult(payload: nil, parsedJSON: nil, error: nil)
        }

        do {
            let payload = try StructuredOutputDecoder.decode(TypedReplyPayload.self, from: response)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let parsedJSON = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) }
            return DecodeResult(payload: payload, parsedJSON: parsedJSON, error: nil)
        } catch let error as StructuredOutputDecodingError {
            return DecodeResult(payload: nil, parsedJSON: nil, error: Self.message(for: error))
        } catch {
            return DecodeResult(payload: nil, parsedJSON: nil, error: error.localizedDescription)
        }
    }

    private static func message(for error: StructuredOutputDecodingError) -> String {
        switch error {
        case .invalidJSONPayload:
            return "Response was not valid JSON."
        case let .decodingFailed(detail):
            return "Response did not match the typed-reply schema: \(detail)"
        }
    }
}
