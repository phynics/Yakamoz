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
    @Environment(\.yakamozRuntime) private var runtime
    @Query private var workspaces: [WorkspaceModel]

    private var attachedWorkspaces: [WorkspaceModel] {
        WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: workspaces)
    }

    var body: some View {
        HStack(spacing: 6) {
            if attachedWorkspaces.isEmpty {
                Menu {
                    Button {
                        pickFolder()
                    } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        pickFolderForTerminal()
                    } label: {
                        Label("Terminal Workspace", systemImage: "terminal")
                    }
                } label: {
                    Label("Add Workspace", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add a workspace to this conversation: a folder or a terminal")
                .accessibilityLabel("Add workspace")
            } else {
                ForEach(attachedWorkspaces) { workspace in
                    chip(for: workspace)
                }

                Menu {
                    Button {
                        pickFolder()
                    } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        pickFolderForTerminal()
                    } label: {
                        Label("Terminal Workspace", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add another workspace: a folder or a terminal")
                .accessibilityLabel("Add another workspace")
            }
        }
    }

    /// A folder chip is a menu offering "Create Terminal" and "Detach"; a terminal chip shows a
    /// terminal icon with a detach button (detaching a terminal also tears down its live session).
    @ViewBuilder
    private func chip(for workspace: WorkspaceModel) -> some View {
        switch workspace.kind {
        case .folder:
            Menu {
                Button {
                    createTerminal(from: workspace)
                } label: {
                    Label("Create Terminal", systemImage: "terminal")
                }
                Button(role: .destructive) {
                    detach(workspace)
                } label: {
                    Label("Detach", systemImage: "xmark.circle")
                }
            } label: {
                Label(workspace.displayName, systemImage: "folder.fill")
                    .font(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(workspace.displayName)
        case .terminal:
            Label(workspace.displayName, systemImage: "terminal")
                .font(.caption)
                .lineLimit(1)
            Button {
                detach(workspace)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Detach \(workspace.displayName)")
            .accessibilityLabel("Detach \(workspace.displayName)")
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

    private func pickFolderForTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Terminal"
        panel.message = """
        Choose a folder to be your terminal's starting directory.

        The terminal shell is NOT jailed to this folder; it can access any file on your system. \
        Each command is approval-gated unless you allow the terminal for the session.
        """

        guard panel.runModal() == .OK, let url = panel.url else { return }
        createTerminalFromFolderURL(url)
    }

    private func attachWorkspace(at url: URL) {
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
    }

    private func createTerminal(from folder: WorkspaceModel) {
        WorkspaceAttachmentSupport.attachTerminal(to: conversation, fromFolder: folder, modelContext: modelContext)
    }

    private func createTerminalFromFolderURL(_ url: URL) {
        WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: conversation, modelContext: modelContext)
    }

    private func detach(_ workspace: WorkspaceModel) {
        let prunedTerminalIds = WorkspaceAttachmentSupport.detachWorkspace(
            id: workspace.id,
            from: conversation,
            modelContext: modelContext
        )
        if let runtime, !prunedTerminalIds.isEmpty {
            Task {
                for id in prunedTerminalIds {
                    await runtime.terminalRegistry.terminate(id: id)
                }
            }
        }
    }
}
