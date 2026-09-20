import Foundation

/// `YakamozNetwork` is Yakamoz's Gnostic consumer client.
///
/// Per ADR 0002 the module embeds `GnosticCore` (and Axoloty, transitively) so
/// `YakamozCore`'s local chat stack never gains an MQTT dependency. The
/// dependency direction is one-way: `YakamozNetwork` depends on `YakamozCore`
/// (for `SecretStoring` and the `Log` facade); `YakamozCore` never depends on
/// `YakamozNetwork`.
///
/// The module presents strongly-typed, `Sendable` value types (`NetworkAscendant`,
/// `NetworkTimelineRef`, `NetworkWorkspaceRef`, and friends) and a
/// `GnosticClientTransport` protocol seam. `GnosticCoreTransport` is the only
/// file in the repository that imports `GnosticCore`; every other type — and the
/// app target — stays free of upstream client types.
public enum YakamozNetwork {
    /// Module format version, bumped when the public surface changes incompatibly.
    public static let version = 1
}
