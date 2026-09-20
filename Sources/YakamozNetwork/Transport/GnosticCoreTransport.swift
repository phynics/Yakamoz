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
        do {
            session = try GnosticConsumerSession(broker: broker, identityName: configuration.identity)
            try await session.start()
        } catch {
            throw GnosticTransportError.connectionFailed(String(describing: error))
        }

        self.session = session
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
