import SwiftData
import SwiftUI
import YakamozCore

/// A toolbar-style control that lets the user attach (or detach) a folder workspace to
/// `conversation`: opens an `NSOpenPanel` directory picker, persists the chosen folder as
/// a `WorkspaceModel`, attaches it to the conversation (`workspaceId`), and enables the
/// folder-jailed filesystem tool ids on `enabledToolIds` so `ChatView` immediately offers
/// them on the next sent message.
struct WorkspacePicker: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Query private var workspaces: [WorkspaceModel]

    /// PKShared filesystem tool ids exposed by any folder workspace (mirrors
    /// `FileSystemWorkspace.toolIds`); enabling a workspace turns these on automatically
    /// so the user doesn't have to separately toggle them in a tools settings screen.
    private static let filesystemToolIds = ["cat", "ls", "find", "search_files", "grep", "change_directory"]

    private var attachedWorkspace: WorkspaceModel? {
        guard let workspaceId = conversation.workspaceId else { return nil }
        return workspaces.first { $0.id == workspaceId }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let workspace = attachedWorkspace {
                Label(workspace.displayName, systemImage: "folder.fill")
                    .font(.caption)
                    .lineLimit(1)
                Button {
                    detachWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Detach workspace")
                .accessibilityLabel("Detach workspace")
            } else {
                Button {
                    pickFolder()
                } label: {
                    Label("Attach Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Attach a folder workspace to this conversation")
                .accessibilityLabel("Attach folder workspace")
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Choose a folder to use as this conversation's workspace."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachWorkspace(at: url)
    }

    private func attachWorkspace(at url: URL) {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        let workspace = WorkspaceModel(
            displayName: url.lastPathComponent,
            folderPath: url.path,
            bookmarkData: bookmark
        )
        modelContext.insert(workspace)

        conversation.workspaceId = workspace.id
        var enabled = Set(conversation.enabledToolIds)
        enabled.formUnion(Self.filesystemToolIds)
        conversation.enabledToolIds = Array(enabled)

        try? modelContext.save()
    }

    private func detachWorkspace() {
        conversation.workspaceId = nil
        conversation.enabledToolIds.removeAll { Self.filesystemToolIds.contains($0) }
        try? modelContext.save()
    }
}
