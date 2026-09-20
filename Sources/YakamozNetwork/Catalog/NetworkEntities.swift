import Foundation

/// Identifies one advertised Gnostic object within a provider's catalog.
///
/// A Gnostic object is scoped to the provider that advertised it: the same
/// `objectID` can legitimately appear under two providers, so the composite key
/// — not the bare `UUID` — is the catalog identity.
public struct NetworkObjectKey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The advertised Gnostic object identifier.
    public let objectID: UUID
    /// The provider identity that advertised the object.
    public let providerID: String

    public init(objectID: UUID, providerID: String) {
        self.objectID = objectID
        self.providerID = providerID
    }

    public var description: String {
        "\(objectID.uuidString)@\(providerID)"
    }
}

/// Where a discovered object came from: the advertising provider and, when the
/// advertisement carries it, the stable serving Node identity.
public struct NetworkProvenance: Hashable, Sendable {
    /// The provider identity that advertised the object.
    public let providerID: String
    /// The stable serving Node identity, when advertised.
    public let nodeID: UUID?

    public init(providerID: String, nodeID: UUID? = nil) {
        self.providerID = providerID
        self.nodeID = nodeID
    }
}

/// The protocol major an object advertised and whether this client can use it.
///
/// Incompatible objects are retained — never dropped — so the UI can explain
/// why they are unavailable. They are simply flagged here.
public struct NetworkCompatibility: Hashable, Sendable {
    /// The advertised protocol major, when the payload carried one.
    public let protocolMajor: Int?
    /// Whether this client supports the advertised protocol major.
    public let isCompatible: Bool

    public init(protocolMajor: Int?, isCompatible: Bool) {
        self.protocolMajor = protocolMajor
        self.isCompatible = isCompatible
    }
}

/// Current health of the backend bound to an Ascendant.
///
/// Health is independent of routability: a failed backend keeps its Ascendant
/// and Timeline relationships available for a bounded reconstruction attempt.
public enum NetworkBackendHealth: String, Sendable, Hashable, CaseIterable {
    /// The backend is bound and serving its Ascendant.
    case healthy
    /// The backend can no longer serve; reconstruction may be attempted.
    case failed
    /// No health has been observed yet.
    case unknown

    /// Maps a wire-reported health string, defaulting to `.unknown`.
    public init(reported: String?) {
        self = NetworkBackendHealth(rawValue: reported ?? "") ?? .unknown
    }
}

/// The trust boundary advertised for a Gnostic Workspace.
public enum NetworkWorkspaceTrustLevel: String, Sendable, Hashable, CaseIterable {
    /// Unrestricted operations within the Workspace boundary.
    case full
    /// Only an allowlisted set of operations is permitted.
    case restricted
    /// Only read-only filesystem operations are permitted.
    case readOnly

    /// Maps a wire-reported trust level, defaulting to `.full`.
    public init(reported: String?) {
        self = NetworkWorkspaceTrustLevel(rawValue: reported ?? "") ?? .full
    }
}

/// The provider-owned lifecycle state advertised for a Workspace.
public enum NetworkWorkspaceStatus: String, Sendable, Hashable, CaseIterable {
    /// The Workspace is present and usable.
    case active
    /// The Workspace's underlying location could not be found.
    case missing
    /// The provider has not determined the Workspace state.
    case unknown

    /// Maps a wire-reported status, defaulting to `.unknown`.
    public init(reported: String?) {
        self = NetworkWorkspaceStatus(rawValue: reported ?? "") ?? .unknown
    }
}

/// The Gnostic-owned effective usability of a Workspace attachment.
public enum NetworkWorkspaceEffectiveStatus: String, Sendable, Hashable, CaseIterable {
    /// The Workspace is currently safe to use.
    case available
    /// The intended Workspace is known but cannot currently be used.
    case unavailable
    /// The Workspace cannot safely be used by this runtime or protocol.
    case unsupported

    /// Maps a wire-reported effective status, defaulting to `.unavailable`.
    public init(reported: String?) {
        self = NetworkWorkspaceEffectiveStatus(rawValue: reported ?? "") ?? .unavailable
    }
}

/// A discovered, remotely hosted Ascendant identity.
public struct NetworkAscendant: Identifiable, Hashable, Sendable {
    /// The provider-scoped catalog identity.
    public let key: NetworkObjectKey
    /// The display name.
    public let name: String
    /// The Ascendant's public description.
    public let summary: String
    /// Stable namespaced capabilities the Ascendant advertises.
    public let capabilities: [String]
    /// Current health of the bound backend.
    public let backendHealth: NetworkBackendHealth
    /// Diagnostic backend kind; not for selection.
    public let backendKind: String?
    /// Diagnostic backend version; not for selection.
    public let backendVersion: String?
    /// Origin of the advertisement.
    public let provenance: NetworkProvenance
    /// Protocol compatibility with this client.
    public let compatibility: NetworkCompatibility

    public var id: NetworkObjectKey { key }

    public init(
        key: NetworkObjectKey,
        name: String,
        summary: String,
        capabilities: [String],
        backendHealth: NetworkBackendHealth,
        backendKind: String?,
        backendVersion: String?,
        provenance: NetworkProvenance,
        compatibility: NetworkCompatibility
    ) {
        self.key = key
        self.name = name
        self.summary = summary
        self.capabilities = capabilities
        self.backendHealth = backendHealth
        self.backendKind = backendKind
        self.backendVersion = backendVersion
        self.provenance = provenance
        self.compatibility = compatibility
    }
}

/// A discovered, Node-owned Gnostic Timeline identity.
///
/// A Gnostic Timeline is remote: it is not a local ``ConversationModel`` and
/// creates no local persistence row (ADR 0002).
public struct NetworkTimelineRef: Identifiable, Hashable, Sendable {
    /// The provider-scoped catalog identity.
    public let key: NetworkObjectKey
    /// The timeline title.
    public let title: String
    /// Whether the timeline is archived.
    public let isArchived: Bool
    /// Whether the timeline is private.
    public let isPrivate: Bool
    /// The Ascendant this timeline is attached to, when advertised.
    public let attachedAscendantID: UUID?
    /// Workspaces this timeline is attached to.
    public let attachedWorkspaceIDs: [UUID]
    /// Origin of the advertisement.
    public let provenance: NetworkProvenance
    /// Protocol compatibility with this client.
    public let compatibility: NetworkCompatibility

    public var id: NetworkObjectKey { key }

    public init(
        key: NetworkObjectKey,
        title: String,
        isArchived: Bool,
        isPrivate: Bool,
        attachedAscendantID: UUID?,
        attachedWorkspaceIDs: [UUID],
        provenance: NetworkProvenance,
        compatibility: NetworkCompatibility
    ) {
        self.key = key
        self.title = title
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.attachedAscendantID = attachedAscendantID
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.provenance = provenance
        self.compatibility = compatibility
    }
}

/// A discovered, remotely hosted Workspace capability resource.
///
/// Distinct from a local Yakamoz Workspace (a folder attached to a local
/// conversation); a Gnostic Timeline can attach a network workspace.
public struct NetworkWorkspaceRef: Identifiable, Hashable, Sendable {
    /// The provider-scoped catalog identity.
    public let key: NetworkObjectKey
    /// The durable workspace URI.
    public let uri: String
    /// The advertised trust boundary.
    public let trustLevel: NetworkWorkspaceTrustLevel
    /// The provider-owned lifecycle state.
    public let status: NetworkWorkspaceStatus
    /// The Gnostic-owned effective usability.
    public let effectiveStatus: NetworkWorkspaceEffectiveStatus
    /// Display names of the safe custom tools the workspace exposes.
    public let toolNames: [String]
    /// Origin of the advertisement.
    public let provenance: NetworkProvenance
    /// Protocol compatibility with this client.
    public let compatibility: NetworkCompatibility

    public var id: NetworkObjectKey { key }

    /// Whether the workspace is currently safe to use.
    public var isAvailable: Bool { effectiveStatus == .available }

    public init(
        key: NetworkObjectKey,
        uri: String,
        trustLevel: NetworkWorkspaceTrustLevel,
        status: NetworkWorkspaceStatus,
        effectiveStatus: NetworkWorkspaceEffectiveStatus,
        toolNames: [String],
        provenance: NetworkProvenance,
        compatibility: NetworkCompatibility
    ) {
        self.key = key
        self.uri = uri
        self.trustLevel = trustLevel
        self.status = status
        self.effectiveStatus = effectiveStatus
        self.toolNames = toolNames
        self.provenance = provenance
        self.compatibility = compatibility
    }
}

/// A single discovered network object, whichever kind it is.
public enum DiscoveredNetworkObject: Hashable, Sendable {
    case ascendant(NetworkAscendant)
    case timeline(NetworkTimelineRef)
    case workspace(NetworkWorkspaceRef)

    /// The provider-scoped identity of the discovered object.
    public var key: NetworkObjectKey {
        switch self {
        case let .ascendant(value): value.key
        case let .timeline(value): value.key
        case let .workspace(value): value.key
        }
    }

    /// A stable label used for deterministic ordering in the browser.
    public var sortName: String {
        switch self {
        case let .ascendant(value): value.name
        case let .timeline(value): value.title
        case let .workspace(value): value.uri
        }
    }
}
