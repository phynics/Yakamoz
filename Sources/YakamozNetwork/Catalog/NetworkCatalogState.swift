import Foundation

/// The pure, deterministic reduction of transport events into browser state.
///
/// Keyed by ``NetworkObjectKey`` (object id + provider id). The reducer retains
/// incompatible objects rather than dropping them, so the UI can show why they
/// are unusable.
public struct NetworkCatalogState: Equatable, Sendable {
    /// Ascendants keyed by their provider-scoped identity.
    public private(set) var ascendants: [NetworkObjectKey: NetworkAscendant]
    /// Timelines keyed by their provider-scoped identity.
    public private(set) var timelines: [NetworkObjectKey: NetworkTimelineRef]
    /// Workspaces keyed by their provider-scoped identity.
    public private(set) var workspaces: [NetworkObjectKey: NetworkWorkspaceRef]

    /// Creates an empty catalog.
    public init() {
        ascendants = [:]
        timelines = [:]
        workspaces = [:]
    }

    /// Whether the catalog holds no objects.
    public var isEmpty: Bool {
        ascendants.isEmpty && timelines.isEmpty && workspaces.isEmpty
    }

    /// Applies one transport event to the catalog.
    ///
    /// `.connectionLost` is a session concern and does not change the catalog.
    public mutating func apply(_ event: GnosticTransportEvent) {
        switch event {
        case let .discovered(object):
            insert(object)
        case let .deadvertised(key):
            remove(key)
        case let .providerEvicted(providerID):
            removeProvider(providerID)
        case .connectionLost:
            break
        }
    }

    /// Inserts or replaces one discovered object.
    ///
    /// A re-advertisement for the same key replaces the prior value, preserving
    /// the latest known snapshot.
    public mutating func insert(_ object: DiscoveredNetworkObject) {
        switch object {
        case let .ascendant(value):
            ascendants[value.key] = value
        case let .timeline(value):
            timelines[value.key] = value
        case let .workspace(value):
            workspaces[value.key] = value
        }
    }

    /// Removes one provider-scoped object.
    public mutating func remove(_ key: NetworkObjectKey) {
        ascendants[key] = nil
        timelines[key] = nil
        workspaces[key] = nil
    }

    /// Removes every object advertised by `providerID`.
    public mutating func removeProvider(_ providerID: String) {
        ascendants = ascendants.filter { $0.key.providerID != providerID }
        timelines = timelines.filter { $0.key.providerID != providerID }
        workspaces = workspaces.filter { $0.key.providerID != providerID }
    }

    /// Ascendants sorted by name (case-insensitive), then key.
    public var sortedAscendants: [NetworkAscendant] {
        ascendants.values.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.key.description < rhs.key.description
        }
    }

    /// Timelines sorted by title (case-insensitive), then key.
    public var sortedTimelines: [NetworkTimelineRef] {
        timelines.values.sorted { lhs, rhs in
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.key.description < rhs.key.description
        }
    }

    /// Workspaces sorted by URI (case-insensitive), then key.
    public var sortedWorkspaces: [NetworkWorkspaceRef] {
        workspaces.values.sorted { lhs, rhs in
            let uriOrder = lhs.uri.localizedCaseInsensitiveCompare(rhs.uri)
            if uriOrder != .orderedSame { return uriOrder == .orderedAscending }
            return lhs.key.description < rhs.key.description
        }
    }

    /// The timelines advertised as attached to `key`, sorted by title.
    public func timelines(forAscendant key: NetworkObjectKey) -> [NetworkTimelineRef] {
        sortedTimelines.filter {
            $0.provenance.providerID == key.providerID && $0.attachedAscendantID == key.objectID
        }
    }

    /// Looks up any kind of object by its provider-scoped identity.
    public func object(for key: NetworkObjectKey) -> DiscoveredNetworkObject? {
        if let ascendant = ascendants[key] { return .ascendant(ascendant) }
        if let timeline = timelines[key] { return .timeline(timeline) }
        if let workspace = workspaces[key] { return .workspace(workspace) }
        return nil
    }
}
