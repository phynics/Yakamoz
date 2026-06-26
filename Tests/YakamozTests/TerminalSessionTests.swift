import Foundation
import Testing
@testable import YakamozCore

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
}
