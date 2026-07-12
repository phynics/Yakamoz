import Foundation
import PKShared

/// `URLSessionWebSocketTask`-backed `MonadWorkspaceRPCConnection` implementing the
/// documented client half of Monad's `/v1/connect` wire format: connect with an
/// `x-monad-client-id` header, read `WorkspaceRPCRequestEnvelope` JSON text frames, write
/// `WorkspaceRPCResponseEnvelope` JSON text frames back.
///
/// This type is intentionally not exercised against a real server in automated tests. Monad's
/// server-initiated request/client-response contract is implemented by MON-API-2, but the full
/// round trip remains a manual-smoke concern because it requires a user-managed authorized
/// server and a configured provider. See Yakamoz's `docs/monad-mode-manual-smoke.md`.
public final class LiveMonadWorkspaceRPCConnection: MonadWorkspaceRPCConnection, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func connect(clientId: UUID) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/connect"), resolvingAgainstBaseURL: false)
        if components?.scheme == "http" { components?.scheme = "ws" }
        if components?.scheme == "https" { components?.scheme = "wss" }
        guard let url = components?.url else {
            throw MonadWorkspaceProviderError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.setValue(clientId.uuidString, forHTTPHeaderField: "x-monad-client-id")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        task.resume()
        self.task = task
    }

    public func incomingRequests() -> AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = self.task
            let decoder = self.decoder
            Task {
                guard let task else {
                    continuation.finish(throwing: MonadWorkspaceProviderError.notConnected)
                    return
                }
                do {
                    while true {
                        let message = try await task.receive()
                        switch message {
                        case let .string(text):
                            guard let data = text.data(using: .utf8) else { continue }
                            let envelope = try decoder.decode(WorkspaceRPCRequestEnvelope.self, from: data)
                            continuation.yield(envelope)
                        case let .data(data):
                            let envelope = try decoder.decode(WorkspaceRPCRequestEnvelope.self, from: data)
                            continuation.yield(envelope)
                        @unknown default:
                            continue
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func send(response: WorkspaceRPCResponseEnvelope) async throws {
        guard let task else {
            throw MonadWorkspaceProviderError.notConnected
        }
        let data = try encoder.encode(response)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    public func disconnect() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

/// Errors specific to the Monad workspace-provider bridge.
public enum MonadWorkspaceProviderError: Error, Sendable {
    case invalidServerURL
    case notConnected
    case unsupportedMethod(String)
    case terminalWorkspacesUnavailable
    case unknownWorkspace
}
