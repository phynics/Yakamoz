import Foundation
import GnosticCore
import Logging
import YakamozCore

/// The production ``GnosticClientTransport``, wrapping `GnosticConsumerSession`.
///
/// **This is the only file in `Sources/` that imports `GnosticCore`.** Every
/// upstream type (`GnosticConsumerSession`, `GnosticBrokerSettings`,
/// `NetworkCatalogEntry`, `NetworkCatalogChange`, `NetworkDynamicValue`) is mapped
/// into the module-local value types here, so no GnosticCore symbol crosses into
/// `YakamozCore` or the app target.
///
/// `GnosticConsumerSession` owns the Axoloty transport, subscription, and catalog;
/// this adapter forwards its `catalogUpdates()` stream as ``GnosticTransportEvent``
/// values and seeds the current snapshot after subscribing.
@MainActor
public final class GnosticCoreTransport: GnosticClientTransport {
    private let stream: AsyncStream<GnosticTransportEvent>
    private let continuation: AsyncStream<GnosticTransportEvent>.Continuation
    private var session: GnosticConsumerSession?
    private var turnClient: GnosticTurnClient?
    private var workspaceClient: GnosticWorkspaceClient?
    private var forwardTask: Task<Void, Never>?
    public init() {
        let pair = AsyncStream<GnosticTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        stream = pair.stream
        continuation = pair.continuation
    }

    public func events() async -> AsyncStream<GnosticTransportEvent> {
        stream
    }

    public func connect(_ configuration: NetworkBrokerConfiguration) async throws {
        await disconnect()

        let broker = GnosticBrokerSettings(
            host: configuration.host,
            port: configuration.port,
            namespace: configuration.namespace,
            username: configuration.username,
            password: configuration.password
        )

        let session: GnosticConsumerSession
        let turnClient: GnosticTurnClient
        let workspaceClient: GnosticWorkspaceClient
        do {
            session = try GnosticConsumerSession(broker: broker, identityName: configuration.identity)
            try await session.start()
            // 120s mirrors Gnostic's documented consumer recipe (README "Run Turns
            // from a consumer"): prompt timeouts below this interrupt long turns.
            turnClient = try session.turnClient(timeout: .seconds(5), promptTimeout: .seconds(120))
            workspaceClient = try session.workspaceClient(timeout: .seconds(5))
        } catch {
            throw GnosticTransportError.connectionFailed(String(describing: error))
        }

        self.session = session
        self.turnClient = turnClient
        self.workspaceClient = workspaceClient
        await startForwarding(from: session)

        // Seed objects that advertised before this subscription was attached.
        let existing = await session.networkObjects(includeIncompatible: true)
        for entry in existing {
            if let object = Self.map(entry) {
                continuation.yield(.discovered(object))
            }
        }
    }

    public func disconnect() async {
        forwardTask?.cancel()
        forwardTask = nil
        turnClient = nil
        workspaceClient = nil
        if let session {
            await session.stop()
            self.session = nil
        }
    }

    public func discover() async throws {
        guard let session else { throw GnosticTransportError.notConnected }
        do {
            try await session.discover()
        } catch {
            throw GnosticTransportError.connectionFailed(String(describing: error))
        }
    }

    public func runTurn(_ request: GnosticTurnRequest) async throws -> AsyncStream<GnosticTurnEvent> {
        guard session != nil, let turnClient else { throw GnosticTransportError.notConnected }
        let providerID = request.timelineKey.providerID
        let pair = AsyncStream<GnosticTurnEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let task = Task {
            do {
                // Subscribe before running so no live update is missed (Gnostic's
                // documented consumer sequence).
                let updates = try await turnClient.updates(
                    for: request.clientTurnID,
                    timelineID: request.timelineID,
                    providerID: providerID
                )
                async let runResult = turnClient.run(
                    message: request.message,
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID,
                    providerID: providerID
                )

                var sawTerminal = false
                for await update in updates {
                    for event in Self.map(update) {
                        pair.continuation.yield(event)
                        if event.isTerminal { sawTerminal = true }
                    }
                }

                do {
                    _ = try await runResult
                } catch {
                    if !sawTerminal {
                        pair.continuation.yield(.failed(
                            message: Self.message(for: error),
                            retryable: true
                        ))
                        sawTerminal = true
                    }
                }
                if !sawTerminal {
                    // The channel subscription ended without a terminal update
                    // (disconnect, provider eviction, retention compaction). Surface a
                    // recoverable failure instead of letting the UI hang on a stream.
                    pair.continuation.yield(.failed(
                        message: "The connection ended before the turn completed.",
                        retryable: true
                    ))
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.yield(.failed(message: Self.message(for: error), retryable: true))
                pair.continuation.finish()
            }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    public func respondToPermission(
        correlationID: String,
        approved: Bool,
        request: GnosticTurnRequest
    ) async throws {
        guard let turnClient else { throw GnosticTransportError.notConnected }
        let providerID = request.timelineKey.providerID
        let response = AscendantPermissionResponse(
            correlationID: correlationID,
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            approved: approved
        )
        try turnClient.respond(to: response, providerID: providerID)
    }

    public func workspaceAttachment(workspaceID: UUID) async throws -> GnosticWorkspaceAttachment {
        guard let workspaceClient else { throw GnosticTransportError.notConnected }
        return Self.map(await workspaceClient.attachmentStatus(workspaceID: workspaceID))
    }

    public func workspaceEffectiveStatus(workspaceID: UUID) async throws -> GnosticWorkspaceEffective {
        guard let workspaceClient else { throw GnosticTransportError.notConnected }
        return Self.map(await workspaceClient.effectiveStatus(workspaceID: workspaceID))
    }

    public func attachWorkspace(workspaceID: UUID, to timelineID: UUID, approved: Bool) async throws {
        guard approved else { throw GnosticTransportError.workspaceApprovalRequired }
        guard let workspaceClient else { throw GnosticTransportError.notConnected }
        do {
            try await workspaceClient.attach(
                workspaceID: workspaceID,
                to: timelineID,
                approved: true
            )
        } catch {
            throw GnosticTransportError.workspaceUnavailable(Self.message(for: error))
        }
    }

    public func detachWorkspace(workspaceID: UUID, from timelineID: UUID) async throws {
        guard let workspaceClient else { throw GnosticTransportError.notConnected }
        do {
            try await workspaceClient.detach(workspaceID: workspaceID, from: timelineID)
        } catch {
            throw GnosticTransportError.workspaceUnavailable(Self.message(for: error))
        }
    }

    private func startForwarding(from session: GnosticConsumerSession) async {
        let updates = await session.catalogUpdates()
        forwardTask = Task { [weak self] in
            for await change in updates {
                guard let self else { return }
                self.forward(change)
            }
        }
    }

    private func forward(_ change: NetworkCatalogChange) {
        switch change {
        case let .advertised(entry):
            if let object = Self.map(entry) {
                continuation.yield(.discovered(object))
            }
        case let .deadvertised(objectID, providerID):
            continuation.yield(.deadvertised(NetworkObjectKey(objectID: objectID, providerID: providerID)))
        case let .providerEvicted(providerID):
            continuation.yield(.providerEvicted(providerID: providerID))
        }
    }

    // MARK: - GnosticCore -> module-local mapping

    /// Maps one turn update into zero or more module-local events.
    ///
    /// Internal rather than private so `GnosticCoreTransportMappingTests` can pin the
    /// vocabulary against recorded `AscendantTurnUpdate` fixtures without a broker.
    static func map(_ update: AscendantTurnUpdate) -> [GnosticTurnEvent] {
        switch update.updateKind {
        case .assistantText:
            return update.text.map { [.textDelta($0)] } ?? []
        case .assistantTextSnapshot:
            return update.text.map { [.textSnapshot($0)] } ?? []
        case .toolCall, .toolState:
            let states = update.toolStates.isEmpty
                ? [update.toolState].compactMap(\.self)
                : update.toolStates
            return states.map { state in
                .toolState(GnosticTurnToolState(
                    toolCallID: state.toolCallID,
                    title: state.title,
                    status: GnosticTurnToolState.Status(rawValue: state.status),
                    content: state.content
                ))
            }
        case .permissionState:
            let states = update.permissionStates.isEmpty
                ? [update.permissionState].compactMap(\.self)
                : update.permissionStates
            return states.map { state in
                .permission(GnosticTurnPermissionRequest(
                    correlationID: state.correlationID,
                    toolCallID: state.toolCallID,
                    title: state.title,
                    status: GnosticTurnPermissionRequest.Status(rawValue: state.status)
                ))
            }
        case .completion:
            return [.completed]
        case .cancellation:
            return [.cancelled]
        case .error:
            return [.failed(
                message: update.text.flatMap { $0.isEmpty ? nil : $0 }
                    ?? update.reasonCode
                    ?? "The Ascendant reported a turn failure.",
                retryable: update.retryable ?? false
            )]
        case nil:
            return []
        }
    }

    private static func message(for error: Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Maps Gnostic's attachment status into the module-local refusal vocabulary.
    static func map(_ status: WorkspaceAttachmentStatus) -> GnosticWorkspaceAttachment {
        switch status {
        case let .available(providerID, uri):
            .available(providerID: providerID, uri: uri)
        case .unavailable:
            .unavailable
        case .malformed:
            .malformed
        case .ambiguous:
            .ambiguous
        case .unsupported:
            .unsupported
        }
    }

    /// Maps Gnostic's effective status into the module-local value, failing closed
    /// to `.unavailable` for a status this build does not know.
    static func map(_ status: GnosticWorkspaceEffectiveStatus) -> GnosticWorkspaceEffective {
        switch status {
        case .available:
            .available
        case .unavailable:
            .unavailable
        case .unsupported:
            .unsupported
        @unknown default:
            .unavailable
        }
    }

    /// Maps one catalog entry, or returns `nil` for a type the browser does not list.
    ///
    /// Internal rather than private so `GnosticCoreTransportMappingTests` can pin the
    /// mapping against recorded `NetworkCatalogEntry` fixtures without a broker.
    static func map(_ entry: NetworkCatalogEntry) -> DiscoveredNetworkObject? {
        if entry.objectType == GnosticObjectType.ascendant {
            return .ascendant(ascendant(from: entry))
        }
        if entry.objectType == GnosticObjectType.timeline {
            return .timeline(timeline(from: entry))
        }
        if entry.objectType == GnosticObjectType.workspace {
            return .workspace(workspace(from: entry))
        }
        if entry.objectType == GnosticObjectType.workspaceTool {
            // Workspace tools augment their workspace; the browser does not list them.
            return nil
        }
        Log.network.debug("network object type not mapped: \(entry.objectType)")
        return nil
    }

    private static func ascendant(from entry: NetworkCatalogEntry) -> NetworkAscendant {
        let properties = entry.knownProperties
        return NetworkAscendant(
            key: key(for: entry),
            name: entry.name,
            summary: string(properties, "ascendantDescription") ?? "",
            capabilities: strings(properties, "capabilities"),
            backendHealth: NetworkBackendHealth(reported: string(properties, "backendHealth")),
            backendKind: string(properties, "backendKind"),
            backendVersion: string(properties, "backendVersion"),
            provenance: provenance(for: entry, properties: properties),
            compatibility: compatibility(for: entry)
        )
    }

    private static func timeline(from entry: NetworkCatalogEntry) -> NetworkTimelineRef {
        let properties = entry.knownProperties
        return NetworkTimelineRef(
            key: key(for: entry),
            title: string(properties, "title") ?? entry.name,
            isArchived: bool(properties, "isArchived") ?? false,
            isPrivate: bool(properties, "isPrivate") ?? false,
            attachedAscendantID: uuid(properties, "attachedAscendantID"),
            attachedWorkspaceIDs: uuids(properties, "attachedWorkspaceIDs"),
            provenance: provenance(for: entry, properties: properties),
            compatibility: compatibility(for: entry)
        )
    }

    private static func workspace(from entry: NetworkCatalogEntry) -> NetworkWorkspaceRef {
        let descriptor = entry.workspace
        return NetworkWorkspaceRef(
            key: key(for: entry),
            uri: descriptor?.uri ?? entry.name,
            trustLevel: NetworkWorkspaceTrustLevel(reported: descriptor?.trustLevel.rawValue),
            status: NetworkWorkspaceStatus(reported: descriptor?.status.rawValue),
            effectiveStatus: NetworkWorkspaceEffectiveStatus(
                reported: descriptor?.effectiveStatus.rawValue ?? entry.effectiveStatus?.rawValue
            ),
            toolNames: descriptor?.tools.map(\.name) ?? [],
            provenance: provenance(for: entry, properties: entry.knownProperties),
            compatibility: compatibility(for: entry)
        )
    }

    private static func key(for entry: NetworkCatalogEntry) -> NetworkObjectKey {
        NetworkObjectKey(objectID: entry.objectID, providerID: entry.providerID)
    }

    private static func provenance(
        for entry: NetworkCatalogEntry,
        properties: [String: NetworkDynamicValue]
    ) -> NetworkProvenance {
        NetworkProvenance(providerID: entry.providerID, nodeID: uuid(properties, "nodeID"))
    }

    private static func compatibility(for entry: NetworkCatalogEntry) -> NetworkCompatibility {
        NetworkCompatibility(protocolMajor: entry.protocolMajor, isCompatible: entry.isProtocolCompatible)
    }

    private static func string(_ values: [String: NetworkDynamicValue], _ key: String) -> String? {
        if case let .string(value) = values[key] { return value }
        return nil
    }

    private static func bool(_ values: [String: NetworkDynamicValue], _ key: String) -> Bool? {
        if case let .bool(value) = values[key] { return value }
        return nil
    }

    private static func uuid(_ values: [String: NetworkDynamicValue], _ key: String) -> UUID? {
        string(values, key).flatMap(UUID.init(uuidString:))
    }

    private static func strings(_ values: [String: NetworkDynamicValue], _ key: String) -> [String] {
        guard case let .array(items) = values[key] else { return [] }
        return items.compactMap { item in
            if case let .string(value) = item { return value }
            return nil
        }
    }

    private static func uuids(_ values: [String: NetworkDynamicValue], _ key: String) -> [UUID] {
        strings(values, key).compactMap(UUID.init(uuidString:))
    }
}
