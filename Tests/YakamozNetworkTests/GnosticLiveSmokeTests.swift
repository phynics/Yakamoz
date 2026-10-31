import Foundation
import PKContracts
import PositronicKit
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
        let transport = LiveGnosticClientTransport()
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
        let result = try await GnosticLiveProbe.invokeAndDetach(
            workspaceID: workspace.key.objectID,
            timelineID: timeline.key.objectID,
            toolID: environment.toolID,
            value: "yakamoz-live-smoke",
            host: environment.host,
            port: environment.port,
            namespace: environment.namespace
        )
        #expect(result.isSuccess)
        #expect(result.output == "yakamoz-live-smoke")
    }
}

/// Opt-in proof that discovery works through the app's transport against a real Node, with
/// no Workspace, Runtime process, or Turn required. Prints what the Node advertises.
@Suite("Live Gnostic discovery", .timeLimit(.minutes(2)))
@MainActor
struct GnosticLiveDiscoveryTests {
    @Test(
        "The app's transport discovers a real Node's objects",
        .enabled(if: ProcessInfo.processInfo.environment["YAKAMOZ_GNOSTIC_SMOKE"] == "1")
    )
    func discoversNodeObjects() async throws {
        let environment = try SmokeEnvironment()
        let session = NetworkClientSession(
            configuration: NetworkBrokerConfiguration(
                host: environment.host,
                port: environment.port,
                namespace: environment.namespace,
                identity: "yakamoz-live-discovery",
                isEnabled: true
            ),
            transport: LiveGnosticClientTransport(),
            retryLimit: 0
        )

        await session.start()
        defer { Task { await session.stop() } }
        #expect(session.state.isOnline)
        await session.forceRefresh()
        for _ in 0..<50 where session.catalog.sortedTimelines.isEmpty {
            try await Task.sleep(for: .milliseconds(200))
        }

        for ascendant in session.catalog.sortedAscendants {
            print("LIVE-MAPPED ascendant name=\(ascendant.name) kind=\(ascendant.backendKind ?? "nil") version=\(ascendant.backendVersion ?? "nil") health=\(ascendant.backendHealth) major=\(ascendant.compatibility.protocolMajor.map(String.init) ?? "nil") compatible=\(ascendant.compatibility.isCompatible) capabilities=\(ascendant.capabilities)")
        }
        for timeline in session.catalog.sortedTimelines {
            print("LIVE-MAPPED timeline title=\(timeline.title) attachedAscendantID=\(timeline.attachedAscendantID?.uuidString ?? "nil") major=\(timeline.compatibility.protocolMajor.map(String.init) ?? "nil") compatible=\(timeline.compatibility.isCompatible)")
        }
        for workspace in session.catalog.sortedWorkspaces {
            print("LIVE-MAPPED workspace uri=\(workspace.uri) major=\(workspace.compatibility.protocolMajor.map(String.init) ?? "nil") compatible=\(workspace.compatibility.isCompatible)")
        }
        for line in try await GnosticLiveProbe.advertisedObjects(
            host: environment.host,
            port: environment.port,
            namespace: environment.namespace
        ) {
            print("LIVE-RAW \(line)")
        }

        let timeline = try #require(session.catalog.sortedTimelines.first, "The Node advertised no Timeline.")
        #expect(timeline.compatibility.protocolMajor == NetworkCompatibility.supportedProtocolMajor)
        #expect(timeline.compatibility.isCompatible)
        #expect(session.catalog.ascendant(for: timeline) != nil)
    }

    @Test(
        "A Network turn through the app's backend streams text and completes",
        .enabled(if: ProcessInfo.processInfo.environment["YAKAMOZ_GNOSTIC_SMOKE"] == "1")
    )
    func runsTurn() async throws {
        let environment = try SmokeEnvironment()
        let transport = LiveGnosticClientTransport()
        let session = NetworkClientSession(
            configuration: NetworkBrokerConfiguration(
                host: environment.host,
                port: environment.port,
                namespace: environment.namespace,
                identity: "yakamoz-live-turn",
                isEnabled: true
            ),
            transport: transport,
            retryLimit: 0
        )
        await session.start()
        defer { Task { await session.stop() } }
        await session.forceRefresh()
        for _ in 0..<50 where session.catalog.sortedTimelines.isEmpty {
            try await Task.sleep(for: .milliseconds(200))
        }
        let timeline = try #require(session.catalog.sortedTimelines.first, "The Node advertised no Timeline.")

        let backend = GnosticBackend(transport: transport, approver: MainActorToolApprover()).scoped(to: timeline.key)
        let stream = try await backend.run(ChatRunRequest(
            timelineID: timeline.key.objectID,
            message: "Yakamoz live discovery Turn",
            tools: []
        ))
        // A completed Network turn ends the stream without a terminal event; failures and
        // cancellation surface as terminal events.
        var text = ""
        var terminal: TurnEvent?
        for await event in stream {
            print("LIVE-TURN \(event)")
            text += event.textContent ?? ""
            if event.isTerminal { terminal = event }
        }
        #expect(terminal == nil)
        #expect(!text.isEmpty)
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
