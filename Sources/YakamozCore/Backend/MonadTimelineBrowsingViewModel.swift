import Foundation
import Observation

/// YAK-MON-11: main-actor view model backing the Monad-mode timeline browsing UI in the
/// sidebar. Lists ordinary server timelines (via `BackendTimelineListing.listTimelines()`)
/// and creates titled server timelines (via `BackendTimelineListing.createTimeline(title:)`),
/// refreshing the list after creation. The server is authoritative — nothing is persisted
/// locally as a `ConversationModel`.
///
/// Mirrors the `MonadWorkspaceViewModel` injection pattern: production wires
/// `MonadYakamozBackend.init(profile:secrets:)`; tests inject a factory that returns a
/// backend over a fully in-memory fake transport, so no network call happens in `make test`.
@MainActor
@Observable
public final class MonadTimelineBrowsingViewModel {
    public typealias BackendFactory = @Sendable (MonadProfile, any SecretStoring) throws -> MonadYakamozBackend

    public enum LoadState: Sendable, Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var timelines: [BackendTimelineSummary] = []
    public private(set) var loadState: LoadState = .loading
    public private(set) var isCreating = false
    public private(set) var actionError: String?

    private let profile: MonadProfile
    private let secrets: any SecretStoring
    private let backendFactory: BackendFactory

    public init(
        profile: MonadProfile,
        secrets: any SecretStoring,
        backendFactory: @escaping BackendFactory = { profile, secrets in
            try MonadYakamozBackend(profile: profile, secrets: secrets)
        }
    ) {
        self.profile = profile
        self.secrets = secrets
        self.backendFactory = backendFactory
    }

    public func load() async {
        loadState = .loading
        actionError = nil
        do {
            let backend = try backendFactory(profile, secrets)
            timelines = try await backend.listTimelines()
            loadState = .loaded
        } catch {
            loadState = .failed(Log.userFriendlyErrorMessage(for: error))
        }
    }

    @discardableResult
    public func createTimeline(title: String) async -> BackendTimelineSummary? {
        isCreating = true
        actionError = nil
        defer { isCreating = false }
        do {
            let backend = try backendFactory(profile, secrets)
            let created = try await backend.createTimeline(title: title)
            await load()
            return created
        } catch {
            actionError = Log.userFriendlyErrorMessage(for: error)
            return nil
        }
    }
}
