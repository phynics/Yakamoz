import Foundation
import PKShared

/// `URLSessionWebSocketTask`-backed `MonadWorkspaceRPCConnection` implementing the
/// documented client half of Monad's `/v1/connect` wire format: connect with an
/// `x-monad-client-id` header, read `WorkspaceRPCRequestEnvelope` JSON text frames, write
/// `WorkspaceRPCResponseEnvelope` JSON text frames back.
///
/// See `MonadWorkspaceRPCConnection`'s doc comment for the honest caveat: this type is
/// implemented against the wire format as documented server-side, but is not exercised by
/// any automated test against a real server (the ticket explicitly excludes live network
/// from automated tests), and the server's current read loop
/// (`WebSocketAPIController.handle`) only decodes inbound frames as `RPCResponse`, not
/// `RPCRequest` — so a real end-to-end round trip through this type has not been verified
/// against a running `monad server`. Manual verification is called out in
/// `MonadWorkspaceProvider`'s smoke-test doc comment.
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
