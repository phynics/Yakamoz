import Foundation
import GnosticCore
import PKContracts
import Testing
import YakamozCore
@testable import YakamozNetwork

/// Opt-in broker-backed proof for #14. The suite stays disabled during normal CI and local
/// verification; ``Scripts/gnostic-smoke.sh`` enables it after starting a real Gnostic Node.
@Suite("Live Gnostic smoke", .timeLimit(.minutes(2)))
@MainActor
struct GnosticLiveSmokeTests {
    @Test(
        "Yakamoz discovers, turns, attaches, and invokes against a real Gnostic Node",
        .enabled(if: ProcessInfo.processInfo.environment["YAKAMOZ_GNOSTIC_SMOKE"] == "1")
    )
    func exercisesLiveNetwork() async throws {
        let environment = try SmokeEnvironment()
        let broker = NetworkBrokerConfiguration(
            host: environment.host,
            port: environment.port,
            namespace: environment.namespace,
            identity: "yakamoz-live-smoke",
            isEnabled: true
        )
        let transport = GnosticCoreTransport()
        let session = NetworkClientSession(
            configuration: broker,
            transport: transport,
            retryLimit: 0
        )

        await session.start()
        do {
            guard session.state.isOnline else {
                throw SmokeError.connectionState(String(describing: session.state))
            }
            await session.forceRefresh()
            try await waitForCatalog(session)

            guard let timeline = session.catalog.sortedTimelines.first else {
                throw SmokeError.missingObject("Timeline")
            }
            guard let workspace = session.catalog.sortedWorkspaces.first else {
                throw SmokeError.missingObject("Workspace")
            }

            let workspaceController = NetworkWorkspaceController(transport: transport)
            await workspaceController.refreshStatuses(workspaceIDs: [workspace.key.objectID])
            guard workspaceController.canAttach(workspaceID: workspace.key.objectID) else {
                throw SmokeError.workspaceUnavailable(workspaceController.refusalReason(workspaceID: workspace.key.objectID) ?? "unknown reason")
            }
            guard await workspaceController.attach(
                workspaceID: workspace.key.objectID,
                to: timeline.key.objectID
            ) else {
                throw SmokeError.workspaceUnavailable(workspaceController.errorMessage ?? "attach failed")
            }

            let backend = GnosticBackend(
                transport: transport,
                approver: MainActorToolApprover()
            ).scoped(to: timeline.key)
            let turnStream = try await backend.run(ChatRunRequest(
                timelineID: timeline.key.objectID,
                message: "Yakamoz live smoke Turn",
                tools: []
            ))
            var terminalEvent: TurnEvent?
            for await event in turnStream {
                if event.isTerminal {
                    terminalEvent = event
                    break
                }
            }
            #expect(terminalEvent != nil)

            try await invokeWorkspace(
                workspace: workspace,
                timeline: timeline,
                environment: environment
            )
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    private func waitForCatalog(_ session: NetworkClientSession) async throws {
        for _ in 0..<30 {
            if !session.catalog.sortedTimelines.isEmpty, !session.catalog.sortedWorkspaces.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SmokeError.missingObject("Timeline or Workspace")
    }

    private func invokeWorkspace(
        workspace: NetworkWorkspaceRef,
        timeline: NetworkTimelineRef,
        environment: SmokeEnvironment
    ) async throws {
        let session = try GnosticConsumerSession(
            broker: GnosticBrokerSettings(
                host: environment.host,
                port: environment.port,
                namespace: environment.namespace
            ),
            identityName: "yakamoz-live-smoke-invoke"
        )
        try await session.start()
        do {
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(5))
            let result = try await client.invoke(
                workspaceID: workspace.key.objectID,
                toolID: environment.toolID,
                arguments: ["value": .string("yakamoz-live-smoke")]
            )
            #expect(result.isSuccess)
            #expect(result.output == "yakamoz-live-smoke")
            try await client.detach(
                workspaceID: workspace.key.objectID,
                from: timeline.key.objectID
            )
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }
}

private struct SmokeEnvironment {
    let host: String
    let port: Int
    let namespace: String
    let toolID: String

    init() throws {
        let variables = ProcessInfo.processInfo.environment
        host = variables["YAKAMOZ_GNOSTIC_HOST"] ?? "127.0.0.1"
        port = try Self.integer(variables["YAKAMOZ_GNOSTIC_PORT"] ?? "1883", named: "port")
        namespace = variables["YAKAMOZ_GNOSTIC_NAMESPACE"] ?? "yakamoz-smoke"
        toolID = variables["YAKAMOZ_SMOKE_TOOL_ID"] ?? "workspace_echo"
    }

    private static func integer(_ value: String, named name: String) throws -> Int {
        guard let result = Int(value) else { throw SmokeError.invalidValue(name, value) }
        return result
    }
}

private enum SmokeError: Error, LocalizedError {
    case connectionState(String)
    case missingObject(String)
    case workspaceUnavailable(String)
    case invalidValue(String, String)

    var errorDescription: String? {
        switch self {
        case let .connectionState(state): "Network session did not become online: \(state)"
        case let .missingObject(object): "Live smoke did not discover a \(object)."
        case let .workspaceUnavailable(reason): "Workspace was not attachable: \(reason)"
        case let .invalidValue(name, value): "Invalid smoke \(name): \(value)"
        }
    }
}
