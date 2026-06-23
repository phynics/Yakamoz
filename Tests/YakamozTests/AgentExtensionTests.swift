import Foundation
import PKPrompt
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// Task 10 extension-seam tests: personas, the current-time prompt section, typed-reply
/// schema validation, and the bounded autonomous-follow-up plugin's continuation policy.
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

    // MARK: - Typed reply schema validation

    @Test
    func typedReplyDecodesValidJSON() {
        let json = #"{"summary":"Done","actionItems":["a","b"]}"#
        let result = TypedReply.decode(from: json)

        #expect(result.error == nil)
        #expect(result.payload == TypedReplyPayload(summary: "Done", actionItems: ["a", "b"]))
        #expect(result.parsedJSON != nil)
    }

    @Test
    func typedReplyDecodesFencedJSON() {
        let json = """
        ```json
        {"summary":"Done","actionItems":[]}
        ```
        """
        let result = TypedReply.decode(from: json)
        #expect(result.error == nil)
        #expect(result.payload == TypedReplyPayload(summary: "Done", actionItems: []))
    }

    @Test
    func typedReplyReportsValidationFailure() {
        // Missing required `actionItems` -> schema/decoding failure surfaced as an error string.
        let json = #"{"summary":"Done"}"#
        let result = TypedReply.decode(from: json)

        #expect(result.payload == nil)
        #expect(result.parsedJSON == nil)
        #expect(result.error != nil)
    }

    @Test
    func typedReplyEmptyInputIsNotAnError() {
        let result = TypedReply.decode(from: "   ")
        #expect(result.payload == nil)
        #expect(result.error == nil)
    }

    @Test
    func typedReplyExposesSchemaJSON() {
        #expect(TypedReply.schema().name == TypedReply.schemaName)
        #expect(TypedReply.schemaJSON()?.isEmpty == false)
    }

    // MARK: - Autonomous follow-up plugin continuation policy

    private func makeTurn() -> CompletedTurn {
        CompletedTurn(
            timelineId: UUID(),
            agentInstanceId: nil,
            turnCount: 1,
            fullResponse: "answer",
            modelName: "test-model"
        )
    }

    @Test
    func pluginEmitsAtMostOneFollowUpPerSend() async throws {
        let plugin = AutonomousFollowUpPlugin()

        let first = try await plugin.afterTurn(makeTurn())
        #expect(first.count == 1)
        #expect(first.first?.role == .user)

        // A second completed turn within the same send must NOT trigger another follow-up.
        let second = try await plugin.afterTurn(makeTurn())
        #expect(second.isEmpty)
    }

    @Test
    func pluginRearmsAfterBeginUserSend() async throws {
        let plugin = AutonomousFollowUpPlugin()

        _ = try await plugin.afterTurn(makeTurn())
        let suppressed = try await plugin.afterTurn(makeTurn())
        #expect(suppressed.isEmpty)

        // Clearing the per-send guard re-arms the plugin for the next user send.
        await plugin.beginUserSend()
        let rearmed = try await plugin.afterTurn(makeTurn())
        #expect(rearmed.count == 1)
    }
}
