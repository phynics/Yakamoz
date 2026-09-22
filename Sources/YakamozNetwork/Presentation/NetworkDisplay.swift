import Foundation

/// One status for a discovered network row or detail header.
///
/// Collapses offline retention, protocol compatibility, and object health into the
/// single state the UI shows, most severe first: incompatible beats offline beats
/// degraded. Free of SwiftUI; the app maps each case to a colour and symbol.
public enum NetworkEntityStatus: Equatable, Sendable {
    /// Advertised and usable.
    case live
    /// Advertised, but its backend or effective status says it cannot serve right now.
    case degraded(String)
    /// No longer advertised; retained only because the user opened it.
    case offline
    /// Advertises a protocol major this client does not support.
    case incompatible(protocolMajor: Int?)

    /// A short, user-facing label.
    public var label: String {
        switch self {
        case .live: "Available"
        case .degraded: "Degraded"
        case .offline: "Offline"
        case .incompatible: "Incompatible"
        }
    }

    /// A sentence explaining a non-live status, or `nil` when live.
    public var explanation: String? {
        switch self {
        case .live:
            nil
        case let .degraded(reason):
            reason
        case .offline:
            "No longer advertised on the network. It reappears when its Node advertises it again."
        case let .incompatible(major):
            "Advertises protocol version \(major.map(String.init) ?? "unknown"), which this version of Yakamoz does not support."
        }
    }

    /// Resolves the status of an Ascendant.
    public static func of(_ ascendant: NetworkAscendant, isOffline: Bool) -> NetworkEntityStatus {
        if !ascendant.compatibility.isCompatible {
            return .incompatible(protocolMajor: ascendant.compatibility.protocolMajor)
        }
        if isOffline { return .offline }
        if ascendant.backendHealth == .failed {
            return .degraded("The Ascendant's backend has failed; its Node may be reconstructing it.")
        }
        return .live
    }

    /// Resolves the status of a Gnostic Timeline.
    public static func of(_ timeline: NetworkTimelineRef, isOffline: Bool) -> NetworkEntityStatus {
        if !timeline.compatibility.isCompatible {
            return .incompatible(protocolMajor: timeline.compatibility.protocolMajor)
        }
        return isOffline ? .offline : .live
    }

    /// Resolves the status of a Network workspace.
    public static func of(_ workspace: NetworkWorkspaceRef, isOffline: Bool) -> NetworkEntityStatus {
        if !workspace.compatibility.isCompatible {
            return .incompatible(protocolMajor: workspace.compatibility.protocolMajor)
        }
        if isOffline { return .offline }
        if !workspace.isAvailable {
            return .degraded(workspace.effectiveStatus.displayDescription)
        }
        return .live
    }
}

/// Whether a network Timeline's composer may send a Network turn.
public enum NetworkChatAvailability: Equatable, Sendable {
    case ready
    /// Sending is blocked; `reason` is shown next to the disabled composer.
    case blocked(reason: String)

    /// The blocking reason, or `nil` when ready.
    public var reason: String? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }

    /// Resolves availability, most fundamental blocker first.
    public static func resolve(
        connection: NetworkConnectionState,
        status: NetworkEntityStatus,
        isArchived: Bool
    ) -> NetworkChatAvailability {
        guard connection.isOnline else {
            return .blocked(reason: "Not connected to the network (\(connection.label.lowercased())).")
        }
        switch status {
        case .incompatible:
            return .blocked(reason: status.explanation ?? "This timeline is incompatible.")
        case .offline:
            return .blocked(reason: "This timeline is offline. Messages can be sent once its Node advertises it again.")
        case .live, .degraded:
            break
        }
        if isArchived {
            return .blocked(reason: "This timeline is archived.")
        }
        return .ready
    }
}

// MARK: - Display strings

public extension NetworkWorkspaceRef {
    /// A short display name derived from the URI: the last path component, else the
    /// host, else the URI itself.
    var displayName: String {
        guard let components = URLComponents(string: uri) else { return uri }
        let lastPath = components.path.split(separator: "/").last.map(String.init)
        if let lastPath, !lastPath.isEmpty { return lastPath.removingPercentEncoding ?? lastPath }
        if let host = components.host, !host.isEmpty { return host }
        return uri
    }
}

public extension NetworkWorkspaceTrustLevel {
    /// A user-facing label.
    var displayName: String {
        switch self {
        case .full: "Full access"
        case .restricted: "Restricted"
        case .readOnly: "Read-only"
        }
    }
}

public extension NetworkWorkspaceStatus {
    /// A user-facing label.
    var displayName: String {
        switch self {
        case .active: "Active"
        case .missing: "Missing"
        case .unknown: "Unknown"
        }
    }
}

public extension NetworkWorkspaceEffectiveStatus {
    /// A user-facing label.
    var displayName: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .unsupported: "Unsupported"
        }
    }

    /// A sentence explaining the status.
    var displayDescription: String {
        switch self {
        case .available: "The workspace is ready to use."
        case .unavailable: "The workspace is known but can't be used right now."
        case .unsupported: "The workspace can't be used safely by this client."
        }
    }
}

public extension NetworkBackendHealth {
    /// A user-facing label.
    var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

public extension NetworkConnectionState {
    /// A compact label for the sidebar header (no failure detail).
    var shortLabel: String {
        switch self {
        case .disabled: "Off"
        case .connecting: "Connecting…"
        case .online: "Connected"
        case .retrying: "Reconnecting…"
        case .failed: "Disconnected"
        }
    }
}

public extension NetworkProvenance {
    /// A one-line provenance string for tooltips and detail rows.
    var displayName: String {
        guard let nodeID else { return providerID }
        return "\(providerID) · Node \(nodeID.uuidString.prefix(8))"
    }
}

public extension NetworkCatalogState {
    /// Timelines that list `workspace` among their attached workspace ids.
    func timelines(attachedTo workspace: NetworkWorkspaceRef) -> [NetworkTimelineRef] {
        sortedTimelines.filter { $0.attachedWorkspaceIDs.contains(workspace.key.objectID) }
    }

    /// The Ascendant a timeline is attached to, when it is listed under the same provider.
    func ascendant(for timeline: NetworkTimelineRef) -> NetworkAscendant? {
        guard let ascendantID = timeline.attachedAscendantID else { return nil }
        return ascendants[NetworkObjectKey(objectID: ascendantID, providerID: timeline.key.providerID)]
    }
}
