import Foundation

/// The sidebar selection for a network entry, routed to the network surface.
public enum NetworkSidebarSelection: Hashable, Sendable {
    /// A discovered Ascendant.
    case ascendant(NetworkObjectKey)
    /// A discovered Gnostic Timeline.
    case timeline(NetworkObjectKey)
    /// A discovered network Workspace.
    case workspace(NetworkObjectKey)
}

/// One Ascendant and its advertised Timelines in the Network group.
public struct NetworkAscendantGroup: Identifiable, Equatable, Sendable {
    /// The Ascendant this group belongs to.
    public let ascendant: NetworkAscendant
    /// Timelines advertised as attached to the Ascendant, sorted by title.
    public let timelines: [NetworkTimelineRef]
    /// Whether the Ascendant is retained from an open session but no longer live.
    public let isOffline: Bool

    public var id: NetworkObjectKey { ascendant.key }

    public init(ascendant: NetworkAscendant, timelines: [NetworkTimelineRef], isOffline: Bool) {
        self.ascendant = ascendant
        self.timelines = timelines
        self.isOffline = isOffline
    }
}

/// The reduced Network group: Ascendants (with timelines), Workspaces, and loose
/// timelines whose Ascendant is not currently listed.
public struct NetworkSidebarGroup: Equatable, Sendable {
    /// Ascendant groups, live first then offline, each sorted by name.
    public let ascendants: [NetworkAscendantGroup]
    /// Network workspaces, live plus offline open sessions, sorted by URI.
    public let workspaces: [NetworkWorkspaceRef]
    /// Open timelines whose Ascendant is not listed at all.
    public let looseTimelines: [NetworkTimelineRef]
    /// Keys retained only because an open session references them.
    public let offlineKeys: Set<NetworkObjectKey>

    /// Whether the group has nothing to show.
    public var isEmpty: Bool {
        ascendants.isEmpty && workspaces.isEmpty && looseTimelines.isEmpty
    }

    /// Whether `key` is retained only by an open session (deadvertised).
    public func isOffline(_ key: NetworkObjectKey) -> Bool {
        offlineKeys.contains(key)
    }

    public init(
        ascendants: [NetworkAscendantGroup],
        workspaces: [NetworkWorkspaceRef],
        looseTimelines: [NetworkTimelineRef],
        offlineKeys: Set<NetworkObjectKey>
    ) {
        self.ascendants = ascendants
        self.workspaces = workspaces
        self.looseTimelines = looseTimelines
        self.offlineKeys = offlineKeys
    }
}

/// Pure grouping of the live catalog plus open-session snapshots for the sidebar.
///
/// Deadvertised entries leave the browser, but an entry the user has opened is
/// retained from `openSessions` and rendered offline/reconnectable until closed.
/// Free of SwiftUI so it is directly unit-testable.
public enum NetworkSidebarPresentation {
    /// Builds the Network group.
    ///
    /// - Parameters:
    ///   - catalog: The live reduced catalog.
    ///   - openSessions: Last-known snapshots of objects the user has opened.
    public static func group(
        catalog: NetworkCatalogState,
        openSessions: [NetworkObjectKey: DiscoveredNetworkObject] = [:]
    ) -> NetworkSidebarGroup {
        var offlineKeys: Set<NetworkObjectKey> = []

        let liveAscendantKeys = Set(catalog.ascendants.keys)
        let offlineAscendants = openSessions.values
            .compactMap { object -> NetworkAscendant? in
                guard case let .ascendant(value) = object, !liveAscendantKeys.contains(value.key) else { return nil }
                return value
            }
            .sorted(by: ascendantOrder)

        for ascendant in offlineAscendants {
            offlineKeys.insert(ascendant.key)
        }

        let allAscendants = catalog.sortedAscendants + offlineAscendants

        let groups = allAscendants.map { ascendant -> NetworkAscendantGroup in
            let isOffline = !liveAscendantKeys.contains(ascendant.key)
            var timelines = catalog.timelines(forAscendant: ascendant.key)
            let liveTimelineKeys = Set(timelines.map(\.key))
            let offlineTimelines = openSessions.values.compactMap { object -> NetworkTimelineRef? in
                guard case let .timeline(value) = object else { return nil }
                guard !liveTimelineKeys.contains(value.key) else { return nil }
                guard value.provenance.providerID == ascendant.key.providerID,
                      value.attachedAscendantID == ascendant.key.objectID else { return nil }
                return value
            }
            timelines.append(contentsOf: offlineTimelines)
            for timeline in offlineTimelines {
                offlineKeys.insert(timeline.key)
            }
            timelines = deduplicated(timelines).sorted(by: timelineOrder)
            return NetworkAscendantGroup(ascendant: ascendant, timelines: timelines, isOffline: isOffline)
        }

        let listedAscendantKeys = Set(groups.map(\.ascendant.key))
        let liveTimelineKeys = Set(catalog.timelines.keys)
        let looseTimelines = openSessions.values.compactMap { object -> NetworkTimelineRef? in
            guard case let .timeline(value) = object else { return nil }
            guard !liveTimelineKeys.contains(value.key) else { return nil }
            if let ascendantID = value.attachedAscendantID,
               listedAscendantKeys.contains(NetworkObjectKey(objectID: ascendantID, providerID: value.provenance.providerID))
            {
                return nil
            }
            return value
        }
        .sorted(by: timelineOrder)

        for timeline in looseTimelines {
            offlineKeys.insert(timeline.key)
        }

        let liveWorkspaceKeys = Set(catalog.workspaces.keys)
        let offlineWorkspaces = openSessions.values.compactMap { object -> NetworkWorkspaceRef? in
            guard case let .workspace(value) = object, !liveWorkspaceKeys.contains(value.key) else { return nil }
            return value
        }
        for workspace in offlineWorkspaces {
            offlineKeys.insert(workspace.key)
        }
        let workspaces = deduplicated(catalog.sortedWorkspaces + offlineWorkspaces).sorted(by: workspaceOrder)

        return NetworkSidebarGroup(
            ascendants: groups,
            workspaces: workspaces,
            looseTimelines: looseTimelines,
            offlineKeys: offlineKeys
        )
    }

    // MARK: - Ordering

    private static func ascendantOrder(_ lhs: NetworkAscendant, _ rhs: NetworkAscendant) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.key.description < rhs.key.description
    }

    private static func timelineOrder(_ lhs: NetworkTimelineRef, _ rhs: NetworkTimelineRef) -> Bool {
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.key.description < rhs.key.description
    }

    private static func workspaceOrder(_ lhs: NetworkWorkspaceRef, _ rhs: NetworkWorkspaceRef) -> Bool {
        let uriOrder = lhs.uri.localizedCaseInsensitiveCompare(rhs.uri)
        if uriOrder != .orderedSame { return uriOrder == .orderedAscending }
        return lhs.key.description < rhs.key.description
    }

    private static func deduplicated(_ timelines: [NetworkTimelineRef]) -> [NetworkTimelineRef] {
        var seen: Set<NetworkObjectKey> = []
        return timelines.filter { seen.insert($0.key).inserted }
    }

    private static func deduplicated(_ workspaces: [NetworkWorkspaceRef]) -> [NetworkWorkspaceRef] {
        var seen: Set<NetworkObjectKey> = []
        return workspaces.filter { seen.insert($0.key).inserted }
    }
}
