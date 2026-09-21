import Foundation
import Observation

/// App-facing state for attaching discovered network Workspaces to a network Timeline
/// (issue #12).
///
/// Attachment is remote-authoritative: the controller asks the transport for the
/// Workspace's advertised attachability, forwards an approved attach/detach, and
/// surfaces failures as a user-facing message. The UI owns the approval step (a
/// confirmation dialog) before calling ``attach(workspaceID:to:)``; the transport
/// refuses an unapproved request regardless.
@MainActor
@Observable
public final class NetworkWorkspaceController {
    /// Last-known attachment status per workspace object id.
    public private(set) var attachments: [UUID: GnosticWorkspaceAttachment] = [:]
    /// Last-known effective usability per workspace object id.
    public private(set) var effectiveStatuses: [UUID: GnosticWorkspaceEffective] = [:]
    /// True while an attach/detach round-trip is in flight.
    public private(set) var isWorking = false
    /// Last operation failure, rendered by the caller and cleared on the next attempt.
    public var errorMessage: String?

    private let transport: any GnosticClientTransport

    public init(transport: any GnosticClientTransport) {
        self.transport = transport
    }

    /// Refreshes attachment and effective status for the given workspaces.
    ///
    /// A status that cannot be fetched (offline, deadvertised) stays at its last
    /// value; the catalog's own presence/absence is the authority on deadvertisement.
    public func refreshStatuses(workspaceIDs: [UUID]) async {
        for workspaceID in workspaceIDs {
            if let attachment = try? await transport.workspaceAttachment(workspaceID: workspaceID) {
                attachments[workspaceID] = attachment
            }
            if let effective = try? await transport.workspaceEffectiveStatus(workspaceID: workspaceID) {
                effectiveStatuses[workspaceID] = effective
            }
        }
    }

    /// Whether an attach may be offered for `workspaceID`.
    ///
    /// Requires a known, attachable advertisement and an effective status that is
    /// either unknown (not yet fetched) or `available` — a malformed, ambiguous,
    /// unsupported, or unavailable workspace is never offered.
    public func canAttach(workspaceID: UUID) -> Bool {
        guard let attachment = attachments[workspaceID] else { return false }
        guard attachment.isAttachable else { return false }
        if let effective = effectiveStatuses[workspaceID], effective != .available {
            return false
        }
        return true
    }

    /// A user-facing reason the attach action is unavailable, or `nil` when offered.
    public func refusalReason(workspaceID: UUID) -> String? {
        guard let attachment = attachments[workspaceID] else {
            return "Checking this workspace's availability…"
        }
        if let reason = attachment.refusalReason { return reason }
        if let effective = effectiveStatuses[workspaceID], effective != .available {
            return "This workspace is \(effective.rawValue) right now."
        }
        return nil
    }

    /// Attaches `workspaceID` to `timelineID` after the caller's explicit approval.
    ///
    /// - Returns: `true` when the Ascendant accepted the attachment.
    @discardableResult
    public func attach(workspaceID: UUID, to timelineID: UUID) async -> Bool {
        await perform {
            try await self.transport.attachWorkspace(
                workspaceID: workspaceID,
                to: timelineID,
                approved: true
            )
        }
    }

    /// Detaches `workspaceID` from `timelineID`.
    @discardableResult
    public func detach(workspaceID: UUID, from timelineID: UUID) async -> Bool {
        await perform {
            try await self.transport.detachWorkspace(workspaceID: workspaceID, from: timelineID)
        }
    }

    private func perform(_ operation: @MainActor () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
            return true
        } catch {
            errorMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}
