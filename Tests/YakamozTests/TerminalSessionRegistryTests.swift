import Foundation
import Testing
@testable import YakamozCore

struct TerminalSessionRegistryTests {
    @Test func sameIdReturnsSameInstanceAcrossTimelineSwitch() async throws {
        let registry = TerminalSessionRegistry()
        let id = UUID()
        let rootURL = URL(fileURLWithPath: "/tmp")

        let first = try await registry.session(for: id, rootURL: rootURL)
        let second = try await registry.session(for: id, rootURL: rootURL)

        #expect(first === second)

        await registry.terminate(id: id)
    }

    @Test func terminateCausesSubsequentCallToReturnNewInstance() async throws {
        let registry = TerminalSessionRegistry()
        let id = UUID()
        let rootURL = URL(fileURLWithPath: "/tmp")

        let first = try await registry.session(for: id, rootURL: rootURL)
        await registry.terminate(id: id)
        let second = try await registry.session(for: id, rootURL: rootURL)

        #expect(first !== second)

        await registry.terminate(id: id)
    }

    @Test func concurrentFirstUseReturnsSameInstance() async throws {
        let registry = TerminalSessionRegistry()
        let id = UUID()
        let rootURL = URL(fileURLWithPath: "/tmp")

        let sessions = try await withThrowingTaskGroup(of: TerminalSession.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await registry.session(for: id, rootURL: rootURL)
                }
            }

            var sessions: [TerminalSession] = []
            for try await session in group {
                sessions.append(session)
            }
            return sessions
        }

        let first = try #require(sessions.first)
        for session in sessions.dropFirst() {
            #expect(session === first)
        }

        await registry.terminate(id: id)
    }

    @Test func allowForSessionAndIsAllowed() async {
        let registry = TerminalSessionRegistry()
        let id = UUID()
        let unknownId = UUID()

        #expect(await registry.isAllowed(id) == false)
        await registry.allowForSession(id)
        #expect(await registry.isAllowed(id) == true)
        #expect(await registry.isAllowed(unknownId) == false)
    }

    @Test func terminateAllTearsDownAllSessionsAndClearsAllowFlags() async throws {
        let registry = TerminalSessionRegistry()
        let idA = UUID()
        let idB = UUID()
        let rootURL = URL(fileURLWithPath: "/tmp")

        let sessionA = try await registry.session(for: idA, rootURL: rootURL)
        _ = try await registry.session(for: idB, rootURL: rootURL)
        await registry.allowForSession(idA)
        await registry.allowForSession(idB)

        await registry.terminateAll()

        #expect(await registry.isAllowed(idA) == false)
        #expect(await registry.isAllowed(idB) == false)

        let newSessionA = try await registry.session(for: idA, rootURL: rootURL)
        #expect(sessionA !== newSessionA)

        await registry.terminate(id: idA)
    }
}
