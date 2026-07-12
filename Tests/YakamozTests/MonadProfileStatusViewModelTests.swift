import Foundation
import MonadClient
import MonadShared
import PKShared
import Testing
@testable import YakamozCore

/// YAK-MON-9: exercises `MonadConnectionStatus` classification and
/// `MonadProfileStatusViewModel`'s profile-editing/status-checking behavior against a fully
/// in-memory fake `MonadClientTransport` — no network. Mirrors the `FakeTransport` pattern from
/// `MonadYakamozBackendTests`.
@Suite("MonadProfileStatusViewModel")
@MainActor
struct MonadProfileStatusViewModelTests {
    fileprivate actor FakeTransport: MonadClientTransport {
        var statusResult: Result<StatusResponse, Error> = .failure(MonadClientError.serverNotReachable)

        func setStatusResult(_ result: Result<StatusResponse, Error>) {
            statusResult = result
        }

        func getStatus() async throws -> StatusResponse {
            try statusResult.get()
        }

        func listTimelines() async throws -> [TimelineResponse] {
            []
        }

        func createTimeline(title: String?) async throws -> TimelineResponse {
            TimelineResponse(id: UUID(), title: title)
        }

        func getTimeline(id: UUID) async throws -> TimelineResponse {
            TimelineResponse(id: id, title: nil)
        }

        func execute(
            timelineId _: UUID,
            message _: String,
            toolOutputs _: [ToolOutputSubmission]?,
            clientTools _: [ToolReference]?
        ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func makeSUT(
        statusResult: Result<StatusResponse, Error> = .failure(MonadClientError.serverNotReachable),
        settingsStore: AppSettingsStore = AppSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
        secrets: any SecretStoring = FakeSecretStore()
    ) async -> MonadProfileStatusViewModel {
        let transport = FakeTransport()
        await transport.setStatusResult(statusResult)
        return MonadProfileStatusViewModel(
            settingsStore: settingsStore,
            secrets: secrets,
            backendFactory: { _, _ in MonadYakamozBackend(transport: transport) }
        )
    }

    // MARK: - Classification

    @Test("healthy status classifies as .healthy")
    func classifyHealthy() {
        let status = StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])
        #expect(MonadConnectionStatus.classify(status) == .healthy)
    }

    @Test("degraded status with unhealthy ai_provider classifies as .providerNotConfigured")
    func classifyProviderNotConfigured() {
        let status = StatusResponse(
            status: .degraded,
            version: "1.0",
            uptime: 1,
            components: [
                "database": ComponentStatus(status: .ok),
                "ai_provider": ComponentStatus(status: .down),
            ]
        )
        #expect(MonadConnectionStatus.classify(status) == .providerNotConfigured)
    }

    @Test("degraded status with only an unrelated unhealthy component classifies as .unexpectedResponse")
    func classifyUnexpectedResponse() {
        let status = StatusResponse(
            status: .degraded,
            version: "1.0",
            uptime: 1,
            components: ["database": ComponentStatus(status: .down)]
        )
        guard case .unexpectedResponse = MonadConnectionStatus.classify(status) else {
            Issue.record("expected .unexpectedResponse")
            return
        }
    }

    @Test("unreachable error classifies as .unreachable")
    func classifyUnreachable() {
        let error = MonadBackendHealthError(clientError: .serverNotReachable)
        guard case .unreachable = MonadConnectionStatus.classify(error) else {
            Issue.record("expected .unreachable")
            return
        }
    }

    @Test("auth failure classifies as .authenticationFailed")
    func classifyAuthFailure() {
        let error = MonadBackendHealthError(clientError: .unauthorized)
        #expect(MonadConnectionStatus.classify(error) == .authenticationFailed)
    }

    // MARK: - checkStatus

    @Test("no saved profile yields .profileMissing without a network call")
    func checkStatusNoProfile() async {
        let sut = await makeSUT()
        await sut.checkStatus()
        #expect(sut.status == .profileMissing)
        #expect(sut.lastCheckedAt != nil)
    }

    @Test("profile with an empty-host URL yields .profileMissing")
    func checkStatusInvalidProfileURL() async throws {
        var settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        settingsStore.lastMonadProfile = try MonadProfile(displayName: "Broken", serverURL: #require(URL(string: "not-a-url")))
        let sut = await makeSUT(settingsStore: settingsStore)
        await sut.checkStatus()
        #expect(sut.status == .profileMissing)
    }

    @Test("valid profile with healthy server yields .healthy")
    func checkStatusHealthy() async throws {
        var settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        settingsStore.lastMonadProfile = try MonadProfile(
            displayName: "Local",
            serverURL: #require(URL(string: "http://127.0.0.1:8080"))
        )
        let sut = await makeSUT(
            statusResult: .success(StatusResponse(status: .ok, version: "1.0", uptime: 1, components: [:])),
            settingsStore: settingsStore
        )
        await sut.checkStatus()
        #expect(sut.status == .healthy)
    }

    @Test("valid profile with unreachable server yields .unreachable")
    func checkStatusUnreachable() async throws {
        var settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        settingsStore.lastMonadProfile = try MonadProfile(
            displayName: "Local",
            serverURL: #require(URL(string: "http://127.0.0.1:8080"))
        )
        let sut = await makeSUT(
            statusResult: .failure(MonadClientError.serverNotReachable),
            settingsStore: settingsStore
        )
        await sut.checkStatus()
        guard case .unreachable = sut.status else {
            Issue.record("expected .unreachable, got \(sut.status)")
            return
        }
    }

    @Test("valid profile with auth failure yields .authenticationFailed")
    func checkStatusAuthFailure() async throws {
        var settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        settingsStore.lastMonadProfile = try MonadProfile(
            displayName: "Local",
            serverURL: #require(URL(string: "http://127.0.0.1:8080"))
        )
        let sut = await makeSUT(
            statusResult: .failure(MonadClientError.unauthorized),
            settingsStore: settingsStore
        )
        await sut.checkStatus()
        #expect(sut.status == .authenticationFailed)
    }

    @Test("valid profile reachable with provider not configured yields .providerNotConfigured")
    func checkStatusProviderNotConfigured() async throws {
        var settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        settingsStore.lastMonadProfile = try MonadProfile(
            displayName: "Local",
            serverURL: #require(URL(string: "http://127.0.0.1:8080"))
        )
        let degraded = StatusResponse(
            status: .degraded,
            version: "1.0",
            uptime: 1,
            components: [
                "database": ComponentStatus(status: .ok),
                "ai_provider": ComponentStatus(status: .down),
            ]
        )
        let sut = await makeSUT(statusResult: .success(degraded), settingsStore: settingsStore)
        await sut.checkStatus()
        #expect(sut.status == .providerNotConfigured)
    }

    // MARK: - Profile editing

    @Test("saveProfile persists a new profile and resets status")
    func saveProfileCreatesProfile() throws {
        let settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        let sut = MonadProfileStatusViewModel(
            settingsStore: settingsStore,
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in MonadYakamozBackend(transport: FakeTransport()) }
        )
        try sut.saveProfile(displayName: "My Server", serverURLString: "http://localhost:9090")
        #expect(sut.activeProfile?.displayName == "My Server")
        #expect(sut.activeProfile?.serverURL == URL(string: "http://localhost:9090"))
        #expect(sut.status == .profileMissing)
    }

    @Test("saveProfile with an invalid URL throws and does not persist")
    func saveProfileInvalidURL() throws {
        let settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        let sut = MonadProfileStatusViewModel(
            settingsStore: settingsStore,
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in MonadYakamozBackend(transport: FakeTransport()) }
        )
        #expect(throws: MonadProfileConfigurationError.invalidServerURL) {
            try sut.saveProfile(displayName: "Broken", serverURLString: "not a url")
        }
        #expect(sut.activeProfile == nil)
    }

    @Test("applyAPIKey without a saved profile throws .noActiveProfile")
    func applyAPIKeyWithoutProfile() throws {
        let settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        let sut = MonadProfileStatusViewModel(
            settingsStore: settingsStore,
            secrets: FakeSecretStore(),
            backendFactory: { _, _ in MonadYakamozBackend(transport: FakeTransport()) }
        )
        #expect(throws: MonadProfileConfigurationError.noActiveProfile) {
            try sut.applyAPIKey("sk-test")
        }
    }

    @Test("applyAPIKey persists through SecretStoring, readable via loadAPIKey")
    func applyAPIKeyPersists() throws {
        let settingsStore = try AppSettingsStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        let secrets = FakeSecretStore()
        let sut = MonadProfileStatusViewModel(
            settingsStore: settingsStore,
            secrets: secrets,
            backendFactory: { _, _ in MonadYakamozBackend(transport: FakeTransport()) }
        )
        try sut.saveProfile(displayName: "Local", serverURLString: "http://127.0.0.1:8080")
        try sut.applyAPIKey("sk-test-key")
        #expect(sut.loadAPIKey() == "sk-test-key")
    }
}
