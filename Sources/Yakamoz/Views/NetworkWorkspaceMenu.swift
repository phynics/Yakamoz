import SwiftUI
import YakamozNetwork

/// Browse, attach, and detach discovered network Workspaces for the selected
/// Timeline (issue #12).
///
/// Attachment always goes through an explicit confirmation; workspaces whose
/// advertisement is missing, malformed, ambiguous, unsupported, or currently
/// unusable cannot be attached (`NetworkWorkspaceController.canAttach`).
struct NetworkWorkspaceMenu: View {
    let timelineKey: NetworkObjectKey
    let session: NetworkClientSession
    let controller: NetworkWorkspaceController

    @State private var pendingAttach: NetworkWorkspaceRef?

    private var workspaces: [NetworkWorkspaceRef] {
        session.catalog.sortedWorkspaces
    }

    private var attachedWorkspaceIDs: Set<UUID> {
        guard case let .timeline(timeline)? = session.catalog.object(for: timelineKey) else { return [] }
        return Set(timeline.attachedWorkspaceIDs)
    }

    /// Re-fetches statuses when the discovered set or the timeline's attachment list changes.
    private var refreshKey: String {
        let discovered = workspaces.map(\.key.objectID.uuidString).joined(separator: ",")
        let attached = attachedWorkspaceIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(discovered)|\(attached)"
    }

    var body: some View {
        Menu {
            if workspaces.isEmpty {
                Text("No network workspaces discovered")
            } else {
                ForEach(workspaces) { workspace in
                    workspaceItem(workspace)
                }
            }
            if controller.isWorking {
                Divider()
                Text("Working…")
            }
        } label: {
            Label("Workspaces", systemImage: "folder.badge.gearshape")
        }
        .task(id: refreshKey) {
            await controller.refreshStatuses(workspaceIDs: workspaces.map(\.key.objectID))
        }
        .confirmationDialog(
            "Attach \u{201C}\(pendingAttach?.uri ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingAttach != nil },
                set: { if !$0 { pendingAttach = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let workspace = pendingAttach {
                Button("Attach") {
                    let workspaceID = workspace.key.objectID
                    pendingAttach = nil
                    Task { await controller.attach(workspaceID: workspaceID, to: timelineKey.objectID) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingAttach = nil
            }
        } message: {
            Text("Its tools become usable by the remote Ascendant during turns on this Timeline.")
        }
        .alert(
            "Workspace Operation Failed",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func workspaceItem(_ workspace: NetworkWorkspaceRef) -> some View {
        let workspaceID = workspace.key.objectID
        if attachedWorkspaceIDs.contains(workspaceID) {
            Text("\(workspace.uri) — attached")
            Button("Detach") {
                Task { await controller.detach(workspaceID: workspaceID, from: timelineKey.objectID) }
            }
        } else {
            Button("Attach \(workspace.uri)…") {
                pendingAttach = workspace
            }
            .disabled(!controller.canAttach(workspaceID: workspaceID))
            .help(controller.refusalReason(workspaceID: workspaceID) ?? "")
        }
    }
}
