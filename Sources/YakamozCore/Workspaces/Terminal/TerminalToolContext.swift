import Foundation

/// Describes one attached terminal workspace for which `YakamozRuntime.resolveTools` should
/// construct the five terminal tools (YAK-T4). `workspaceId` keys the shared `TerminalSession`
/// in the registry; `rootURL` is the shell's initial working directory.
public struct TerminalToolContext: Sendable, Equatable {
    public let workspaceId: UUID
    public let rootURL: URL

    public init(workspaceId: UUID, rootURL: URL) {
        self.workspaceId = workspaceId
        self.rootURL = rootURL
    }
}
