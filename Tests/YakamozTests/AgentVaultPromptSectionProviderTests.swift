import Foundation
import PKPrompt
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("AgentVaultPromptSectionProvider")
struct AgentVaultPromptSectionProviderTests {
    /// Builds a vault dir. `nil` for a file => that file is not created; a string (incl. "")
    /// => written. `extraMemoryNote` writes an arbitrary `Memory/some-topic.md` body to prove
    /// note bodies are never injected.
    private func makeVault(
        workflow: String?,
        notes: String?,
        index: String?,
        extraMemoryNote: String? = nil
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        if let workflow {
            try workflow.write(to: root.appendingPathComponent("WORKFLOW.md"), atomically: true, encoding: .utf8)
        }
        if let notes {
            try notes.write(to: root.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        }
        if let index {
            try index.write(to: root.appendingPathComponent("Memory/INDEX.md"), atomically: true, encoding: .utf8)
        }
        if let extraMemoryNote {
            try extraMemoryNote.write(to: root.appendingPathComponent("Memory/some-topic.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func ids(_ sections: [any Prompt]) -> [String] {
        sections.compactMap { ($0 as? TextPrompt)?.id }
    }

    /// Renders the provider's sections to a map of id -> text via the public
    /// `AssembledPrompt.render()` path (`RenderedPrompt.sectionsByID`), so tests can assert
    /// on content without `TextPrompt`'s private render closure.
    private func renderedText(for sections: [any Prompt]) async -> [String: String] {
        let promptSections = sections.flatMap { $0.resolveSections() }
        guard let assembled = try? AssembledPrompt(sections: promptSections) else { return [:] }
        let rendered = await assembled.render()
        return rendered.sectionsByID
    }

    @Test("injects agent instructions then vault files in workflow notes index order")
    func injectsInstructionsThenOrderedVaultFiles() async throws {
        let root = try makeVault(workflow: "workflow-body", notes: "notes-body", index: "index-body")
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "You are a test agent.") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))

        #expect(sections.count == 4)
        #expect(ids(sections) == [
            "yakamoz.agent-vault.instructions",
            "yakamoz.agent-vault.workflow",
            "yakamoz.agent-vault.notes",
            "yakamoz.agent-vault.index",
        ])

        let byID = await renderedText(for: sections)
        #expect(byID["yakamoz.agent-vault.instructions"] == "You are a test agent.")
        #expect(byID["yakamoz.agent-vault.workflow"] == "workflow-body")
        #expect(byID["yakamoz.agent-vault.notes"] == "notes-body")
        #expect(byID["yakamoz.agent-vault.index"] == "index-body")
    }

    @Test("home timelines include principal framing beside the vault sections")
    func homeTimelineIncludesPrincipalFraming() async throws {
        let root = try makeVault(workflow: "workflow-body", notes: "notes-body", index: "index-body")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentID = UUID()
        let timelineID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "You are a test agent.") },
            rootForAgent: { _ in root },
            isHomeTimeline: { $0 == timelineID }
        )

        let sections = await provider.sections(for: .init(timelineId: timelineID, agentInstanceId: agentID, message: "hi"))

        #expect(ids(sections) == [
            "yakamoz.agent-vault.instructions",
            "yakamoz.agent-vault.home",
            "yakamoz.agent-vault.workflow",
            "yakamoz.agent-vault.notes",
            "yakamoz.agent-vault.index",
        ])
        #expect((await renderedText(for: sections))["yakamoz.agent-vault.home"]?.contains("principal") == true)
    }

    @Test("no agentInstanceId injects nothing and does not throw")
    func noAgentInstanceInjectsNothing() async throws {
        let root = try makeVault(workflow: "w", notes: "n", index: "i")
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in nil },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: nil, message: "hi"))
        #expect(sections.isEmpty)
    }

    @Test("unknown backend instance (agent lookup returns nil) injects nothing")
    func unknownBackendInstanceInjectsNothing() async throws {
        let root = try makeVault(workflow: "w", notes: "n", index: "i")
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in nil },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: UUID(), message: "hi"))
        #expect(sections.isEmpty)
    }

    @Test("missing vault files inject nothing; agent instructions still present")
    func missingFilesInjectNothing() async throws {
        let root = try makeVault(workflow: nil, notes: nil, index: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "instruct") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))
        // Only agent instructions survive.
        #expect(ids(sections) == ["yakamoz.agent-vault.instructions"])
    }

    @Test("empty vault files inject nothing")
    func emptyFilesInjectNothing() async throws {
        let root = try makeVault(workflow: "", notes: "", index: "")
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "instruct") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))
        // Empty files are omitted; instructions remain.
        #expect(ids(sections) == ["yakamoz.agent-vault.instructions"])
    }

    @Test("empty agent instructions are omitted too")
    func emptyInstructionsOmitted() async throws {
        let root = try makeVault(workflow: "w", notes: "n", index: "i")
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))
        #expect(ids(sections) == [
            "yakamoz.agent-vault.workflow",
            "yakamoz.agent-vault.notes",
            "yakamoz.agent-vault.index",
        ])
    }

    @Test("NOTES.md is capped at ~8KB with a visible truncation marker")
    func notesCappedWithMarker() async throws {
        let root = try makeVault(workflow: "w", notes: String(repeating: "n", count: 9000), index: "i")
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "instruct") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))
        let byID = await renderedText(for: sections)
        let notesText = try #require(byID["yakamoz.agent-vault.notes"])
        #expect(notesText.contains("[truncated"))
        #expect(notesText.utf8.count <= 8 * 1024 + 64)
    }

    @Test("Memory/INDEX.md is capped at ~8KB with a visible truncation marker")
    func indexCappedWithMarker() async throws {
        let root = try makeVault(workflow: "w", notes: "n", index: String(repeating: "i", count: 9000))
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "instruct") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))
        let byID = await renderedText(for: sections)
        let indexText = try #require(byID["yakamoz.agent-vault.index"])
        #expect(indexText.contains("[truncated"))
        #expect(indexText.utf8.count <= 8 * 1024 + 64)
    }

    @Test("arbitrary Memory/*.md note bodies are never injected")
    func memoryNoteBodiesNotInjected() async throws {
        let secretNoteBody = "THIS SHOULD NEVER APPEAR IN THE PROMPT"
        let root = try makeVault(
            workflow: "w",
            notes: "n",
            index: "i",
            extraMemoryNote: secretNoteBody
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let agentID = UUID()
        let provider = AgentVaultPromptSectionProvider(
            agentForInstance: { _ in AgentVaultSnapshot(id: agentID, instructions: "instruct") },
            rootForAgent: { _ in root }
        )
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: agentID, message: "hi"))

        // No section id corresponds to the arbitrary memory note.
        #expect(!ids(sections).contains("yakamoz.agent-vault.some-topic"))

        // And the rendered text never contains the secret note body.
        let byID = await renderedText(for: sections)
        for text in byID.values {
            #expect(!text.contains(secretNoteBody))
        }
    }
}
