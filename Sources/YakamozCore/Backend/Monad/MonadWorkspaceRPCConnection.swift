import Foundation
import PKShared

/// The client side of Monad's `/v1/connect` WebSocket RPC channel — the seam
/// `MonadWorkspaceProvider` uses to receive server-pushed `workspace/*` requests and send
/// back responses, without depending on `URLSessionWebSocketTask` directly.
///
/// **Status: seam only, not exercised against a real server.** The wire format this
/// protocol assumes (`x-monad-client-id` header on connect, `WorkspaceRPCRequestEnvelope`
/// text frames in, `WorkspaceRPCResponseEnvelope` text frames out) is concretely defined
/// server-side today in `Monad/Sources/MonadServer/Controllers/WebSocketAPIController.swift`
/// and `Monad/Sources/MonadServer/Services/WebSocketConnectionManager.swift`, but there is
/// no client-side WebSocket implementation anywhere in the workspace to test against, and
/// `WebSocketAPIController`'s current read loop only decodes inbound frames as
/// `RPCResponse` (i.e. today the server only expects the *client* to reply to
/// server-initiated calls — it does not yet read `RPCRequest` frames from a client, which
/// this protocol's `incomingRequests` stream would need). `LiveMonadWorkspaceRPCConnection`
/// implements the client half of the documented wire format faithfully, but automated
/// tests exercise `MonadWorkspaceProvider`'s dispatch logic exclusively through a fake
/// conforming to this protocol — never through `URLSessionWebSocketTask` or a live socket,
/// per the ticket's explicit "no live network, no live WebSocket" requirement.
public protocol MonadWorkspaceRPCConnection: Sendable {
    /// Opens the WebSocket connection for `clientId` and begins surfacing inbound RPC
    /// requests on `incomingRequests`. Safe to call once per connection lifetime;
    /// reconnection is the caller's (`MonadWorkspaceProvider`'s) responsibility.
    func connect(clientId: UUID) async throws

    /// Server-pushed RPC requests, in arrival order. The stream finishes when the
    /// connection is closed (by `disconnect()`, a server-initiated close, or an error).
    func incomingRequests() -> AsyncThrowingStream<WorkspaceRPCRequestEnvelope, Error>

    /// Sends a response for a previously-received request back to the server.
    func send(response: WorkspaceRPCResponseEnvelope) async throws

    /// Closes the connection. `incomingRequests()`'s stream finishes after this returns.
    func disconnect() async
}
