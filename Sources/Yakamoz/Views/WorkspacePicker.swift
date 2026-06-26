import SwiftData
import SwiftUI
import YakamozCore

/// A toolbar-style control that lets the user attach (or detach) one or more folder
/// workspaces to `conversation`: opens an `NSOpenPanel` directory picker, persists the
/// chosen folder as a `WorkspaceModel`, attaches it to the conversation
/// (`attachedWorkspaceIds`), and enables the folder-jailed filesystem tool ids on
/// `enabledToolIds` so `ChatView` immediately offers them on the next sent message.
/// Renders one chip per attached workspace, each independently detachable.
struct WorkspacePicker: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Query private var workspaces: [WorkspaceModel]

    private var attachedWorkspaces: [WorkspaceModel] {
        WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: workspaces)
    }

    var body: some View {
        HStack(spacing: 6) {
            if attachedWorkspaces.isEmpty {
                Button {
                    pickFolder()
                } label: {
                    Label("Attach Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Attach a folder workspace to this conversation")
                .accessibilityLabel("Attach folder workspace")
            } else {
                ForEach(attachedWorkspaces) { workspace in
                    Label(workspace.displayName, systemImage: "folder.fill")
                        .font(.caption)
                        .lineLimit(1)
                    Button {
                        detachWorkspace(id: workspace.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Detach \(workspace.displayName)")
                    .accessibilityLabel("Detach \(workspace.displayName)")
                }

                Button {
                    pickFolder()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Attach another folder workspace")
                .accessibilityLabel("Attach another folder workspace")
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
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
    }

    private func detachWorkspace(id: UUID) {
        WorkspaceAttachmentSupport.detachWorkspace(id: id, from: conversation, modelContext: modelContext)
    }
}
