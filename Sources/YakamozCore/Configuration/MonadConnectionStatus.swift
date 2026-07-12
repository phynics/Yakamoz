import Foundation
import MonadClient
import MonadShared

/// App-safe classification of an active `MonadProfile`'s connection/readiness, driving
/// `MonadProfileStatusViewModel`.
///
/// This is the type the `Yakamoz` app target actually binds to (per the app-target boundary:
/// it must never see `MonadShared.StatusResponse`/`MonadBackendHealthError` directly). It
/// distinguishes the four failure states YAK-MON-9 calls out, plus the healthy case:
///
/// - `.profileMissing` — no `MonadProfile` saved locally, or one with an empty/invalid
///   `serverURL`. Purely local; never requires a network call to detect.
/// - `.unreachable` — the server could not be reached at all (network error, connection
///   refused, DNS failure, etc).
/// - `.authenticationFailed` — the server was reached but rejected the configured API key.
/// - `.providerNotConfigured` — the server is reachable and authenticated, but its own
///   `ai_provider` health component is not `.ok` (the server has no LLM provider configured
///   on its side). Yakamoz only *observes* this; it never writes the server's provider
///   configuration (out of scope for this ticket).
/// - `.healthy` — the server is reachable and fully ready.
/// - `.unexpectedResponse` — the server responded, but in a shape/status combination this
///   classifier doesn't otherwise recognize (e.g. a decoding failure, or a degraded status
///   whose component isn't `ai_provider`).
public enum MonadConnectionStatus: Sendable, Equatable {
    case profileMissing
    case unreachable(message: String)
    case authenticationFailed
    case providerNotConfigured
    case healthy
    case unexpectedResponse(message: String)

    /// Classifies a successfully-decoded `StatusResponse` from the server's `/status` endpoint.
    ///
    /// The server (`Monad/Sources/MonadServer/Controllers/StatusAPIController.swift`) reports
    /// overall `.degraded` whenever either its `database` or `ai_provider` health component is
    /// not `.ok`. When the `ai_provider` component specifically is unhealthy, that's exactly
    /// the "reachable but provider not configured" state this ticket needs to surface
    /// distinctly from a generic unreachable/auth failure.
    static func classify(_ status: StatusResponse) -> MonadConnectionStatus {
        guard status.status != .ok else { return .healthy }

        if let aiProviderStatus = status.components["ai_provider"]?.status, aiProviderStatus != .ok {
            return .providerNotConfigured
        }

        return .unexpectedResponse(message: "Server reported status \(status.status.rawValue).")
    }

    /// Classifies a thrown `MonadBackendHealthError` (unreachable server, auth failure, or an
    /// incompatible/undecodable response) into the same app-safe status space.
    static func classify(_ error: MonadBackendHealthError) -> MonadConnectionStatus {
        switch error {
        case let .unreachable(underlying):
            .unreachable(message: underlying)
        case .authenticationFailed:
            .authenticationFailed
        case let .incompatibleResponse(underlying):
            .unexpectedResponse(message: underlying)
        }
    }
}

public extension MonadYakamozBackend {
    /// Fetches and classifies the server's current status for `MonadProfileStatusViewModel`,
    /// collapsing both the decoded-response and thrown-error paths into one app-safe
    /// `MonadConnectionStatus`. Never throws — every failure mode maps to a status case.
    func fetchConnectionStatus() async -> MonadConnectionStatus {
        do {
            let status = try await transport.getStatus()
            return MonadConnectionStatus.classify(status)
        } catch let error as MonadClientError {
            return MonadConnectionStatus.classify(MonadBackendHealthError(clientError: error))
        } catch {
            return .unexpectedResponse(message: "\(error)")
        }
    }
}
