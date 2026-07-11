import Foundation
import PKPrompt
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("AgentVaultPromptSectionProvider")
struct AgentVaultPromptSectionProviderTests {
    @Test("injects vault files in workflow notes index order and caps mutable files")
    func injectsOrderedCappedFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try "workflow".write(to: root.appendingPathComponent("WORKFLOW.md"), atomically: true, encoding: .utf8)
        try String(repeating: "n", count: 9_000).write(to: root.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try "index".write(to: root.appendingPathComponent("Memory/INDEX.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let provider = AgentVaultPromptSectionProvider(rootForAgent: { _ in root })
        let sections = await provider.sections(for: .init(timelineId: UUID(), agentInstanceId: id, message: "hi"))
        #expect(sections.count == 3)
        let ids = sections.compactMap { ($0 as? TextPrompt)?.id }
        #expect(ids == ["yakamoz.agent-vault.workflow", "yakamoz.agent-vault.notes", "yakamoz.agent-vault.index"])
    }
}
