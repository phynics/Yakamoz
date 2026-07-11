import SwiftData
import SwiftUI
import YakamozCore

/// ATW-8: the workspace library — every persisted `WorkspaceModel`, the timelines
/// referencing each, create/delete actions. Deletion prunes the workspace from every
/// referencing timeline's `attachedWorkspaceIds` (`WorkspaceAttachmentSupport.deleteWorkspace`).
struct WorkspaceLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime

    @Query private var workspaces: [WorkspaceModel]
    @Query(filter: ConversationListQuery.standardPredicate) private var conversations: [ConversationModel]

    @State private var pendingDeletion: WorkspaceModel?

    var body: some View {
        NavigationStack {
            List {
                ForEach(workspaces) { workspace in
                    row(for: workspace)
                }
            }
            .navigationTitle("Workspace Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createFolderWorkspace()
                    } label: {
                        Label("New Folder Workspace", systemImage: "folder.badge.plus")
                    }
                }
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.displayName ?? "Workspace")?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let workspace = pendingDeletion { delete(workspace) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This removes it from every timeline that references it.")
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func row(for workspace: WorkspaceModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: workspace.kind == .terminal ? "terminal" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(workspace.displayName).font(.body.weight(.medium))
                Spacer()
                Button(role: .destructive) {
                    pendingDeletion = workspace
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(workspace.displayName)")
            }
            Text(workspace.folderPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            let referencing = referencingTimelines(workspace)
            if referencing.isEmpty {
                Text("Not attached to any timeline").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Attached to: \(referencing.map(\.title).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func referencingTimelines(_ workspace: WorkspaceModel) -> [ConversationModel] {
        conversations.filter { $0.allAttachedWorkspaceIds.contains(workspace.id) }
    }

    private func createFolderWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to add to the workspace library."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        let workspace = WorkspaceModel(displayName: url.lastPathComponent, folderPath: url.path, bookmarkData: bookmark)
        modelContext.insert(workspace)
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save library workspace", metadata: ["workspaceID": "\(workspace.id)"])
        }
    }

    private func delete(_ workspace: WorkspaceModel) {
        let isTerminal = workspace.kind == .terminal
        let id = workspace.id
        WorkspaceAttachmentSupport.deleteWorkspace(workspace, modelContext: modelContext)
        if isTerminal, let runtime {
            Task { await runtime.terminalRegistry.terminate(id: id) }
        }
    }
}
