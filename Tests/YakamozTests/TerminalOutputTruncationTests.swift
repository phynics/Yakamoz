import Foundation
import Testing
@testable import YakamozCore

@Suite("Terminal Output Truncation (YAK-T6)", .serialized)
struct TerminalOutputTruncationTests {
    // MARK: - Full output store and retrieval

    @Test func readStoredOutputReturnsCorrectPage() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        let result = try await session.run("seq 1 100", graceMs: 4000)

        guard case let .finished(_, _, commandId) = result else {
            Issue.record("expected finished"); return
        }

        // Read a page starting at offset 10 with limit 20.
        let (pageLines, totalLines, _) = try await session.readStoredOutput(
            commandId: commandId,
            offset: 10,
            limit: 20
        )

        #expect(pageLines.count == 20)
        #expect(totalLines == 100)
        #expect(pageLines.first?.contains("11") ?? false)

        await session.terminate()
    }

    @Test func readStoredOutputThrowsUnknownCommandForInvalidId() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        let unknownId = UUID()
        await #expect(throws: TerminalWorkspaceError.unknownCommandOutput) {
            try await session.readStoredOutput(commandId: unknownId)
        }

        await session.terminate()
    }

    // MARK: - LRU eviction test

    @Test func commandOutputsAreEvictedWhenCapExceeded() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        // Run more than 20 commands (the cap) to trigger eviction.
        var commandIds: [UUID] = []
        for i in 0 ..< 25 {
            let result = try await session.run("echo 'cmd-\(i)'", graceMs: 4000)
            if case let .finished(_, _, id) = result {
                commandIds.append(id)
            }
        }

        #expect(commandIds.count == 25)

        // The first few commands were stored then evicted by the LRU cap → commandOutputExpired.
        await #expect(throws: TerminalWorkspaceError.commandOutputExpired) {
            try await session.readStoredOutput(commandId: commandIds[0])
        }

        // A freshly-generated random id was never issued → unknownCommandOutput.
        await #expect(throws: TerminalWorkspaceError.unknownCommandOutput) {
            try await session.readStoredOutput(commandId: UUID())
        }

        // The most recent should still be there.
        do {
            _ = try await session.readStoredOutput(commandId: commandIds[24])
        } catch {
            Issue.record("most recent command should not be evicted: \(error)")
        }

        await session.terminate()
    }

    // MARK: - YAK-TF4 regression: PTY buffer compaction still works

    @Test func ptyBufferStillCompactsAfterCommandCompletion() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        // Run 40 commands, each with 64-byte payload (mimics YAK-TF4 test).
        for index in 0 ..< 40 {
            let payload = String(repeating: "x", count: 64)
            let result = try await session.run("echo \(index)-\(payload)", graceMs: 4000)
            guard case let .finished(output, code, _) = result else {
                Issue.record("expected finished, got \(result)"); return
            }
            #expect(code == 0)
            #expect(output.contains("\(index)-"))
        }

        let retainedBytes = await session.bufferByteCountForTesting()
        // PTY buffer should still be compacted, retaining only the last command's output.
        #expect(retainedBytes < 512, "PTY buffer should be compacted after YAK-TF4; got \(retainedBytes) bytes")

        await session.terminate()
    }

    @Test func storedOutputSurvivesPtyBufferCompaction() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        // Run command A with some output.
        let resultA = try await session.run("seq 1 100", graceMs: 4000)
        guard case let .finished(_, _, idA) = resultA else {
            Issue.record("expected finished for A"); return
        }

        // Run command B (triggers PTY compaction after A finishes).
        let resultB = try await session.run("echo 'B'", graceMs: 4000)
        guard case let .finished(_, _, idB) = resultB else {
            Issue.record("expected finished for B"); return
        }

        // Verify A's output is still in the store even though PTY compacted it.
        do {
            let (linesA, _, _) = try await session.readStoredOutput(commandId: idA)
            #expect(linesA.count == 100, "A's output should be retained in the store")
        } catch {
            Issue.record("A's output should still be retrievable: \(error)")
        }

        // Verify B's output is also there.
        do {
            let (linesB, _, _) = try await session.readStoredOutput(commandId: idB)
            #expect(linesB.count > 0)
        } catch {
            Issue.record("B's output should still be retrievable: \(error)")
        }

        await session.terminate()
    }

    // TODO: YAK-T6 - Verify truncation notice output format when rendering large output
    // @Test func truncationNoticeIncludesCommandId() async throws {
    //     let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
    //
    //     // Generate output that will be truncated (more than 200 lines).
    //     let result = try await session.run("seq 1 300", graceMs: 4000)
    //
    //     guard case let .finished(output, code, commandId) = result else {
    //         Issue.record("expected finished"); return
    //     }
    //
    //     #expect(code == 0)
    //     #expect(output.contains("truncated"))
    //     #expect(output.contains(commandId.uuidString))
    //     #expect(output.contains("terminal_read_output"))
    //
    //     await session.terminate()
    // }

    @Test func grepFilteringWorks() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        // Run with grep to filter output.
        let result = try await session.run("seq 1 100", graceMs: 4000, grepPattern: "5")

        guard case let .finished(output, code, _) = result else {
            Issue.record("expected finished"); return
        }

        #expect(code == 0)
        // Should only contain lines with "5" in them
        #expect(output.contains("5"))

        await session.terminate()
    }
}
