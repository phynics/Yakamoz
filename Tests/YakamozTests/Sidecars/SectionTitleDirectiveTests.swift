import Foundation
import JSONSchemaBuilder
import PKShared
import Testing
@testable import YakamozCore

@Suite("SectionTitleDirective")
struct SectionTitleDirectiveTests {
    @Test("instruction embeds the current section title for comparison")
    func instructionEmbedsCurrentSection() {
        let directive = SectionTitleDirective.make(currentSectionTitle: "Exploring the bug")
        #expect(directive.instruction.contains("Exploring the bug"))
        #expect(directive.name == "section_title")
        #expect(directive.timing == .afterResponse)
    }

    @Test("instruction handles no current section (start of conversation)")
    func instructionHandlesNoCurrentSection() {
        let directive = SectionTitleDirective.make(currentSectionTitle: nil)
        #expect(!directive.instruction.isEmpty)
        #expect(directive.instruction.contains("No section has been marked"))
    }

    @Test("payload schema marks section title as nullable, not required")
    func schemaAllowsNullSectionTitle() throws {
        let schema = SectionTitleDirectivePayload.schema.definition()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        // `@Schemable` camelCases a `sectionTitle` Swift property to a `sectionTitle`
        // JSON Schema key by default (no key encoding strategy override on the type).
        let prop = properties["sectionTitle"]
        #expect(prop != nil)
        let required = json["required"] as? [String]
        #expect(required?.contains("sectionTitle") != true, "sectionTitle must be optional so the model can decline")
    }

    @Test("directive is structurally equal across calls with the same current section title")
    func directiveIsDeterministic() {
        let a = SectionTitleDirective.make(currentSectionTitle: "Phase 1")
        let b = SectionTitleDirective.make(currentSectionTitle: "Phase 1")
        #expect(a == b)
    }
}
