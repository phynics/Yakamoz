import Foundation
import Testing
@testable import YakamozCore

@Suite("AgentVaultBrowsing")
struct AgentVaultBrowsingTests {
    private func makeAgent(in tempDir: URL) -> AgentModel {
        AgentModel(name: "Ada", instructions: "", vaultPath: tempDir.path)
    }

    private func withTempVault(_ body: (AgentModel, URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = makeAgent(in: dir)
        try body(agent, dir)
    }

    @Test("Reading NOTES.md before it exists returns empty string")
    func readsMissingNotesAsEmpty() throws {
        try withTempVault { agent, _ in
            #expect(AgentVaultBrowsing.readNotes(agent: agent) == "")
        }
    }

    @Test("Writing then reading NOTES.md round-trips")
    func writesAndReadsNotes() throws {
        try withTempVault { agent, _ in
            try AgentVaultBrowsing.writeNotes(agent: agent, contents: "hello vault")
            #expect(AgentVaultBrowsing.readNotes(agent: agent) == "hello vault")
        }
    }

    @Test("Lists Memory notes, excluding INDEX.md, sorted and with a preview line")
    func listsMemoryNotes() throws {
        try withTempVault { agent, dir in
            let memoryDir = dir.appending(path: "Memory", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            try "# Memory Index\n".write(to: memoryDir.appending(path: "INDEX.md"), atomically: true, encoding: .utf8)
            try "description: a note about zebras\nmore text".write(
                to: memoryDir.appending(path: "zebras.md"), atomically: true, encoding: .utf8
            )
            try "first line\nsecond line".write(
                to: memoryDir.appending(path: "apples.md"), atomically: true, encoding: .utf8
            )

            let notes = AgentVaultBrowsing.listMemoryNotes(agent: agent)

            #expect(notes.map(\.title) == ["apples", "zebras"])
            #expect(notes.first { $0.title == "zebras" }?.preview == "a note about zebras")
            #expect(notes.first { $0.title == "apples" }?.preview == "first line")
        }
    }

    @Test("Renders wiki-links as distinct segments")
    func rendersWikiLinks() {
        let segments = AgentVaultBrowsing.renderWikiLinks("see [[Project X]] for details")
        #expect(segments == [
            .text("see "),
            .wikiLink("Project X"),
            .text(" for details"),
        ])
    }

    @Test("Plain text with no wiki-links renders as a single segment")
    func rendersPlainTextUnchanged() {
        let segments = AgentVaultBrowsing.renderWikiLinks("no links here")
        #expect(segments == [.text("no links here")])
    }
}
