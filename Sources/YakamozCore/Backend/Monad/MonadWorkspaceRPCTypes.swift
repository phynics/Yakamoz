import Foundation
import PKShared

// Wire-format types mirroring Monad server's workspace RPC envelope
// (`Monad/Sources/MonadServer/Models/Workspace/WorkspaceRPC.swift`) and the five
// `workspace/*` methods `RemoteWorkspace` sends to an attached workspace's owning
// client over the `/v1/connect` WebSocket.
//
// These types are defined independently here rather than imported, because the
// authoritative definitions live in the `MonadServer` target (a Hummingbird server
// target, not a client-facing library) which Yakamoz does not and should not depend on.
// The JSON shape below is kept byte-for-byte compatible with the server's `Codable`
// conformances (same field names, same `CodingKeys` via default synthesis) so that a
// real server's `JSONEncoder`/`JSONDecoder` output round-trips through these types
// without any translation layer.
//
// **Known contract gap (see `MonadWorkspaceProvider`'s doc comment):** the server's
// `RemoteWorkspace` routes every RPC call to a client purely by `clientId` — no
// workspace id travels in `RPCRequest.params` for `workspace/executeTool`,
// `workspace/readFile`, `workspace/writeFile`, `workspace/deleteFile`, or
// `workspace/listFiles`. That means the current wire contract cannot disambiguate
// *which* attached workspace an incoming call targets when a single client has more
// than one attached workspace registered. This is a real limitation of the protocol as
// it exists today, not an omission in this file.

/// Generic RPC request envelope sent by the server to a connected client.
public struct WorkspaceRPCRequestEnvelope: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: AnyCodable?

    public init(id: String, method: String, params: AnyCodable?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Generic RPC response envelope a client sends back to the server.
public struct WorkspaceRPCResponseEnvelope: Codable, Sendable {
    public let id: String
    public let result: AnyCodable?
    public let error: String?

    public init(id: String, result: AnyCodable? = nil, error: String? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

// MARK: - workspace/executeTool

struct WorkspaceRPCToolExecutionRequest: Codable {
    let toolId: String
    let parameters: [String: AnyCodable]
}

struct WorkspaceRPCToolExecutionResponse: Codable {
    let status: String // "success" or "error"
    let output: String
    let error: String?

    static func success(output: String) -> Self {
        .init(status: "success", output: output, error: nil)
    }

    static func failure(_ message: String) -> Self {
        .init(status: "error", output: "", error: message)
    }
}

// MARK: - workspace/readFile / writeFile / deleteFile / listFiles

struct WorkspaceRPCReadFileRequest: Codable {
    let path: String
}

struct WorkspaceRPCWriteFileRequest: Codable {
    let path: String
    let content: String
}

struct WorkspaceRPCDeleteFileRequest: Codable {
    let path: String
}

struct WorkspaceRPCListFilesRequest: Codable {
    let path: String
}

/// The `workspace/*` method names `RemoteWorkspace` sends. Terminal-workspace RPC
/// methods are intentionally not modeled here — YAK-MON-5 scopes terminal workspace
/// support out (see `MonadWorkspaceProvider`).
enum WorkspaceRPCMethod: String {
    case executeTool = "workspace/executeTool"
    case readFile = "workspace/readFile"
    case writeFile = "workspace/writeFile"
    case deleteFile = "workspace/deleteFile"
    case listFiles = "workspace/listFiles"
}
