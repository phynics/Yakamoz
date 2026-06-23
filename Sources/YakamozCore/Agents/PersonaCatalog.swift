import Foundation
import PKShared

/// A single persona: a named, reusable bundle of system instructions a conversation can adopt.
///
/// Built-in personas are identified by a stable string `slug` (so a fresh install always
/// resolves "helpful" et al. the same way). Custom personas are persisted as `PersonaModel`
/// rows keyed by `UUID`; `PersonaDefinition` is the `Sendable` value used in-memory and
/// across the runtime boundary.
public struct PersonaDefinition: Sendable, Equatable, Identifiable, Codable {
    /// Stable string identity for built-ins (e.g. "helpful"); the `UUID` string for custom personas.
    public let id: String
    public let name: String
    public let instructions: String
    /// `true` for the four shipped presets in `PersonaCatalog.builtIns`; `false` for user-created personas.
    public let isBuiltIn: Bool

    public init(id: String, name: String, instructions: String, isBuiltIn: Bool = true) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }
}

/// The four shipped personas plus helpers to convert a persona into an `AgentTemplate`
/// (so it can seed an `AgentInstance` via `AgentInstanceManager.createInstance(from:)`).
public enum PersonaCatalog {
    public static let builtIns: [PersonaDefinition] = [
        PersonaDefinition(id: "helpful", name: "Helpful Assistant", instructions: "Be accurate, direct, and helpful."),
        PersonaDefinition(id: "reviewer", name: "Terse Code Reviewer", instructions: "Lead with concrete defects. Be concise."),
        PersonaDefinition(id: "socratic", name: "Socratic Tutor", instructions: "Teach by asking one focused question at a time."),
        PersonaDefinition(id: "json", name: "JSON-only", instructions: "Return only JSON matching the supplied schema."),
    ]

    /// The built-in persona resolved by its stable slug, if any.
    public static func builtIn(id: String) -> PersonaDefinition? {
        builtIns.first { $0.id == id }
    }

    /// Builds an `AgentTemplate` whose `systemPrompt` is this persona's instructions.
    ///
    /// The template carries a deterministic `id` derived from the persona id when it is a
    /// UUID, otherwise a fresh `UUID` (built-in slugs are not UUIDs). Used to seed an
    /// `AgentInstance` via `AgentInstanceManagerProtocol.createInstance(from:name:description:)`.
    public static func makeTemplate(from persona: PersonaDefinition, now: Date = Date()) -> AgentTemplate {
        let templateId = UUID(uuidString: persona.id) ?? UUID()
        return AgentTemplate(
            id: templateId,
            name: persona.name,
            description: "Persona: \(persona.name)",
            systemPrompt: persona.instructions,
            createdAt: now,
            updatedAt: now
        )
    }
}
