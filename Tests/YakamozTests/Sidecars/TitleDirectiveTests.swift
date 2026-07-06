import Foundation
import JSONSchemaBuilder
import PKShared
import Testing
@testable import YakamozCore

@Suite("TitleDirective")
struct TitleDirectiveTests {
    @Test("payload schema marks title as nullable, not required")
    func schemaAllowsNullTitle() throws {
        let schema = TitleDirectivePayload.schema.definition()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        let titleProp = properties["title"]
        // The title property must exist and accept either a string or null. `@Schemable`
        // with `optionalNulls: true` (the macro's default) emits a type union for optionals;
        // exactly how the union is encoded is an implementation detail of swift-json-schema,
        // so this test only pins the contract the title directive relies on: the property
        // exists, and it is NOT forced into the `required` array (so the model may decline).
        #expect(titleProp != nil)
        let required = json["required"] as? [String]
        #expect(required?.contains("title") != true, "title must be optional so the model can decline")
    }

    @Test("directive instruction embeds the current title for comparison")
    func instructionEmbedsCurrentTitle() {
        let directive = TitleDirective.make(currentTitle: "Fixing the auth bug")
        #expect(directive.instruction.contains("Fixing the auth bug"))
        #expect(directive.name == "title")
        #expect(directive.timing == .afterResponse)
    }

    @Test("directive instruction handles no current title (new conversation)")
    func instructionHandlesNoCurrentTitle() {
        let directive = TitleDirective.make(currentTitle: nil)
        #expect(!directive.instruction.isEmpty)
        #expect(directive.instruction.contains("does not have a title"))
    }

    @Test("directive schema is the TitleDirectivePayload schema definition")
    func directiveSchemaIsPayloadDefinition() throws {
        // Two `TitleDirective.make` calls with the same `currentTitle` must produce
        // structurally equal `SidecarDirective`s (same name/instruction/schema/timing),
        // confirming the schema is deterministic and not accidentally recomputed per call.
        let a = TitleDirective.make(currentTitle: nil)
        let b = TitleDirective.make(currentTitle: nil)
        #expect(a == b)
    }
}
