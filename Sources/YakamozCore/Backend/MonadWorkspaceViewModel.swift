import ErrorKit
import Foundation
import MonadClient
import Observation
import PKShared
import PositronicKit

/// YAK-MON-6: main-actor view model backing the Monad-mode timeline workspace
/// attachment UI. Manages workspace list state for one server-backed timeline:
/// loads attached workspaces from the server, handles folder pick → provider
/// registration → server attach, handles detach, and refreshes after each change.
///
/// The server is authoritative for timeline/workspace membership — nothing is
/// persisted locally. Every `load()` call fetches the current attached set from
/// the server's `listTimelineWorkspaces` endpoint.
///
/// Terminal workspaces are surfaced via `MonadWorkspacePresentation.Kind.terminal`
/// with an `.unavailable` availability so the UI can disable them. The
/// `MonadWorkspaceProvider` only accepts folder workspaces; terminal workspaces
/// are never registered or attached through this view model.
@MainActor
@Observable
public final class MonadWorkspaceViewModel {
    public typealias BackendFactory = @Sendable (MonadProfile, any SecretStoring) throws -> MonadYakamozBackend
    public typealias ProviderFactory = @Sendable (MonadProfile, any SecretStoring) throws -> MonadWorkspaceProvider

    public enum LoadState: Sendable, Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var timelineSummary: BackendTimelineSummary?
    public private(set) var attachedWorkspaces: [MonadWorkspacePresentation] = []
    public private(set) var loadState: LoadState = .loading
    public private(set) var isAttaching = false
    public private(set) var actionError: String?

    private let timelineId: UUID
    private let profile: MonadProfile
    private let secrets: any SecretStoring
    private let backendFactory: BackendFactory
    private let providerFactory: ProviderFactory
    private var provider: MonadWorkspaceProvider?

    public init(
        timelineId: UUID,
        profile: MonadProfile,
        secrets: any SecretStoring,
        backendFactory: @escaping BackendFactory = { profile, secrets in
            try MonadYakamozBackend(profile: profile, secrets: secrets)
        },
        providerFactory: @escaping ProviderFactory = MonadWorkspaceViewModel.defaultProviderFactory
    ) {
        self.timelineId = timelineId
        self.profile = profile
        self.secrets = secrets
        self.backendFactory = backendFactory
        self.providerFactory = providerFactory
    }

    public func load() async {
        loadState = .loading
        actionError = nil
        do {
            let backend = try backendFactory(profile, secrets)
            async let summary = backend.loadTimeline(id: timelineId)
            async let workspaces = backend.listTimelineWorkspaces(timelineId: timelineId)
            let (s, w) = try await (summary, workspaces)
            timelineSummary = s
            attachedWorkspaces = w.attached.map(MonadWorkspacePresentation.init(workspace:))
            loadState = .loaded
        } catch {
            loadState = .failed(Log.userFriendlyErrorMessage(for: error))
        }
    }

    public func attachFolder(at url: URL) async {
        isAttaching = true
        actionError = nil
        defer { isAttaching = false }
        do {
            let folder = FileSystemWorkspace(rootURL: url)
            if provider == nil {
                provider = try providerFactory(profile, secrets)
            }
            guard let provider else { return }
            let workspace = try await provider.start(folder: folder)
            let backend = try backendFactory(profile, secrets)
            try await backend.attachWorkspace(workspace.id, toTimeline: timelineId)
            await load()
        } catch {
            actionError = Log.userFriendlyErrorMessage(for: error)
        }
    }

    public func detachWorkspace(_ workspaceId: UUID) async {
        actionError = nil
        do {
            let backend = try backendFactory(profile, secrets)
            try await backend.detachWorkspace(workspaceId, fromTimeline: timelineId)
            await load()
        } catch {
            actionError = Log.userFriendlyErrorMessage(for: error)
        }
    }

    public func cleanup() async {
        await provider?.stop()
        provider = nil
    }

    public static let defaultProviderFactory: ProviderFactory = { profile, secrets in
        let apiKey = try profile.apiKey(secrets: secrets)
        let configuration = ClientConfiguration(baseURL: profile.serverURL, apiKey: apiKey)
        let client = MonadClient(configuration: configuration)
        let registrationTransport = LiveMonadWorkspaceRegistrationTransport(client: client)
        let serverURL = profile.serverURL
        let connectionFactory: @Sendable () -> any MonadWorkspaceRPCConnection = {
            LiveMonadWorkspaceRPCConnection(baseURL: serverURL, apiKey: apiKey)
        }
        return MonadWorkspaceProvider(
            registrationTransport: registrationTransport,
            connectionFactory: connectionFactory
        )
    }
}
