import Foundation
import YakamozCore
import YakamozNetwork

/// In-memory `SecretStoring` fake. Never touches the real store, so these tests
/// are safe to run on CI without entitlements.
final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func read(account: String) throws -> String? {
        storage[account]
    }

    func write(_ value: String, account: String) throws {
        storage[account] = value
    }

    func delete(account: String) throws {
        storage.removeValue(forKey: account)
    }
}

/// A throwaway `UserDefaults` suite so settings tests never leak into each other.
enum TestDefaults {
    static func make() -> UserDefaults {
        let suiteName = "YakamozNetworkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Thread-safe recorder for the injected backoff sleeper.
final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []

    func record(_ duration: Duration) {
        lock.lock()
        storage.append(duration)
        lock.unlock()
    }

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Builders for deterministic module-local entities.
enum TestEntities {
    static func key(_ objectID: UUID, provider: String = "provider.one") -> NetworkObjectKey {
        NetworkObjectKey(objectID: objectID, providerID: provider)
    }

    static func compatibility(major: Int? = 2, compatible: Bool = true) -> NetworkCompatibility {
        NetworkCompatibility(protocolMajor: major, isCompatible: compatible)
    }

    static func ascendant(
        key: NetworkObjectKey,
        name: String,
        health: NetworkBackendHealth = .healthy,
        nodeID: UUID? = nil,
        compatible: Bool = true
    ) -> NetworkAscendant {
        NetworkAscendant(
            key: key,
            name: name,
            summary: "\(name) summary",
            capabilities: ["me.atkn.gnostic.capability.turn.text"],
            backendHealth: health,
            backendKind: "positronic",
            backendVersion: "6.0.0",
            provenance: NetworkProvenance(providerID: key.providerID, nodeID: nodeID),
            compatibility: compatibility(compatible: compatible)
        )
    }

    static func timeline(
        key: NetworkObjectKey,
        title: String,
        attachedAscendantID: UUID? = nil,
        compatible: Bool = true
    ) -> NetworkTimelineRef {
        NetworkTimelineRef(
            key: key,
            title: title,
            isArchived: false,
            isPrivate: false,
            attachedAscendantID: attachedAscendantID,
            attachedWorkspaceIDs: [],
            provenance: NetworkProvenance(providerID: key.providerID),
            compatibility: compatibility(compatible: compatible)
        )
    }

    static func workspace(
        key: NetworkObjectKey,
        uri: String,
        effectiveStatus: NetworkWorkspaceEffectiveStatus = .available,
        compatible: Bool = true
    ) -> NetworkWorkspaceRef {
        NetworkWorkspaceRef(
            key: key,
            uri: uri,
            trustLevel: .full,
            status: .active,
            effectiveStatus: effectiveStatus,
            toolNames: [],
            provenance: NetworkProvenance(providerID: key.providerID),
            compatibility: compatibility(compatible: compatible)
        )
    }
}
