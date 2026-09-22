import SwiftUI
import YakamozNetwork

/// Browse, attach, and detach discovered network Workspaces for the selected
/// Timeline (issue #12).
///
/// Attached workspaces come first, each with its own Detach; the rest follow with an
/// Attach… action or — since macOS menus show no tooltips — the reason it can't be
/// attached, inline. Attachment always goes through an explicit confirmation; workspaces
/// whose advertisement is missing, malformed, ambiguous, unsupported, or currently
/// unusable cannot be attached (`NetworkWorkspaceController.canAttach`).
struct NetworkWorkspaceMenu: View {
    let timelineKey: NetworkObjectKey
    let session: NetworkClientSession
    @Bindable var controller: NetworkWorkspaceController

    @State private var pendingAttach: NetworkWorkspaceRef?

    private var workspaces: [NetworkWorkspaceRef] {
        session.catalog.sortedWorkspaces
    }

    private var attachedWorkspaceIDs: Set<UUID> {
        guard case let .timeline(timeline)? = session.object(for: timelineKey) else { return [] }
        return Set(timeline.attachedWorkspaceIDs)
    }

    private var attached: [NetworkWorkspaceRef] {
        workspaces.filter { attachedWorkspaceIDs.contains($0.key.objectID) }
    }

    private var available: [NetworkWorkspaceRef] {
        workspaces.filter { !attachedWorkspaceIDs.contains($0.key.objectID) }
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
                Text("No network workspaces advertised")
            }
            if !attached.isEmpty {
                Section("Attached") {
                    ForEach(attached) { workspace in
                        Menu(workspace.displayName) {
                            Text(workspace.trustLevel.displayName)
                            Button("Detach", role: .destructive) {
                                let workspaceID = workspace.key.objectID
                                Task { await controller.detach(workspaceID: workspaceID, from: timelineKey.objectID) }
                            }
                        }
                    }
                }
            }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { workspace in
                        availableItem(workspace)
                    }
                }
            }
        } label: {
            if controller.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                // Same label scheme as the local `ConversationWorkspacesMenu`.
                Label(label, systemImage: "externaldrive.connected.to.line.below")
                    .labelStyle(.titleAndIcon)
            }
        }
        .disabled(controller.isWorking)
        .help(attached.isEmpty
            ? "Attach a network workspace to this timeline"
            : "\(attached.count) network workspace\(attached.count == 1 ? "" : "s") attached")
        .accessibilityLabel("Network Workspaces")
        .task(id: refreshKey) {
            await controller.refreshStatuses(workspaceIDs: workspaces.map(\.key.objectID))
        }
        .confirmationDialog(
            "Attach \u{201C}\(pendingAttach?.displayName ?? "")\u{201D}?",
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
            if let workspace = pendingAttach {
                Text("The remote Ascendant will be able to use its tools (\(workspace.trustLevel.displayName.lowercased())) during turns on this timeline.")
            }
        }
        .errorAlert("Couldn't Update Workspace", message: $controller.errorMessage)
    }

    private var label: String {
        switch attached.count {
        case 0: "No Workspace"
        case 1: attached[0].displayName
        default: "\(attached.count) Workspaces"
        }
    }

    @ViewBuilder
    private func availableItem(_ workspace: NetworkWorkspaceRef) -> some View {
        switch controller.menuAction(workspaceID: workspace.key.objectID, attachedIDs: attachedWorkspaceIDs) {
        case .attach:
            Button("Attach \(workspace.displayName)…") {
                pendingAttach = workspace
            }
        case let .unavailable(reason):
            Button("\(workspace.displayName) — \(reason)") {}
                .disabled(true)
        case .detach:
            EmptyView()
        }
    }
}
