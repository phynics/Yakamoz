import Foundation
import PKPrompt
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// Extension-seam tests: personas and the current-time prompt section.
struct AgentExtensionTests {
    // MARK: - Personas

    @Test
    func builtInPersonasHaveExpectedIdsAndInstructions() {
        let byId = Dictionary(uniqueKeysWithValues: PersonaCatalog.builtIns.map { ($0.id, $0) })

        #expect(Set(byId.keys) == ["helpful", "reviewer", "socratic", "json"])
        #expect(byId["helpful"]?.instructions == "Be accurate, direct, and helpful.")
        #expect(byId["reviewer"]?.instructions == "Lead with concrete defects. Be concise.")
        #expect(byId["socratic"]?.instructions == "Teach by asking one focused question at a time.")
        #expect(byId["json"]?.instructions == "Return only JSON matching the supplied schema.")
        let allBuiltIn = PersonaCatalog.builtIns.allSatisfy(\.isBuiltIn)
        #expect(allBuiltIn)
    }

    @Test
    func personaConvertsToAgentTemplateCarryingInstructions() throws {
        let persona = try #require(PersonaCatalog.builtIn(id: "reviewer"))
        let template = PersonaCatalog.makeTemplate(from: persona)

        #expect(template.name == "Terse Code Reviewer")
        #expect(template.systemPrompt == "Lead with concrete defects. Be concise.")
        #expect(template.composedInstructions.contains("Lead with concrete defects."))
    }

    @Test
    func customPersonaEditPersists() throws {
        // A custom persona round-trips through its Codable value with edits preserved.
        let original = PersonaDefinition(
            id: UUID().uuidString,
            name: "My Persona",
            instructions: "Original instructions.",
            isBuiltIn: false
        )
        let edited = PersonaDefinition(
            id: original.id,
            name: "My Persona (edited)",
            instructions: "Updated instructions.",
            isBuiltIn: false
        )

        let data = try JSONEncoder().encode(edited)
        let decoded = try JSONDecoder().decode(PersonaDefinition.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == "My Persona (edited)")
        #expect(decoded.instructions == "Updated instructions.")
        #expect(decoded.isBuiltIn == false)
    }

    // MARK: - Current-time prompt section

    @Test
    func currentTimeSectionIsDeterministicWithFixedClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let provider = CurrentTimeSectionProvider(now: { fixed })
        let context = PromptBuildContext(timelineId: UUID(), agentInstanceId: nil, message: "hi")

        let sections = await provider.sections(for: context)
        #expect(sections.count == 1)

        let expectedContent = CurrentTimeSectionProvider.content(for: fixed)
        #expect(expectedContent == "Current time (UTC): 2023-11-14T22:13:20Z")

        // The section must carry the stable id, low priority, volatile cache, .keep compression.
        // `TextPrompt` exposes these traits publicly; the concrete `PromptSection`/`PromptNode`
        // accessors are `package` and not reachable from the app/test boundary.
        let textPrompt = try #require(sections.first as? TextPrompt)
        #expect(textPrompt.id == CurrentTimeSectionProvider.sectionID)
        #expect(textPrompt.priority == PromptPriority.low.rawValue)
        #expect(textPrompt.cachePolicy == .volatile)
        #expect(textPrompt.compression == .keep)
    }

}
