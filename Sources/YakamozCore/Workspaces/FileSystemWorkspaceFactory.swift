import Foundation
import PKContracts
import PositronicKit

/// `WorkspaceFactory` adapter that builds `FileSystemWorkspace` instances rooted at the
/// folder path carried on a `WorkspaceReference.rootPath`.
///
/// This is the factory `YakamozRuntime` hands to `PositronicKit` so that, when a
/// timeline's attached workspace reference resolves to a folder-backed workspace, the
/// runtime can materialize a confined `FileSystemWorkspace` without `PositronicKit`
/// needing to know anything about `FileManager`-backed storage.
public struct FileSystemWorkspaceFactory: WorkspaceFactory {
    public init() {}

    public func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        guard let rootPath = reference.rootPath else {
            throw WorkspaceError.invalidWorkspaceType
        }
        let rootURL = URL(fileURLWithPath: rootPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.workspaceNotFound
        }
        return FileSystemWorkspace(id: reference.id, rootURL: rootURL)
    }
}
