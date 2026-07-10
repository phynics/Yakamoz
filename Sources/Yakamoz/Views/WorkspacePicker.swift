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
                addWorkspaceMenu(label: Label("Add Workspace", systemImage: "folder.badge.plus"))
            } else {
                ForEach(attachedWorkspaces) { workspace in
                    chip(for: workspace)
                }

                addWorkspaceMenu(label: Image(systemName: "plus.circle"))
            }
        }
    }

    @ViewBuilder
    private func addWorkspaceMenu<L: View>(label: L) -> some View {
        Menu {
            Button {
                pickFolder()
            } label: {
                Label("Folder Workspace", systemImage: "folder")
            }

            Button {
                pickFolderForTerminal()
            } label: {
                Label("Terminal Workspace", systemImage: "terminal")
            }
        } label: {
            label
        }
        .buttonStyle(.borderless)
        .help("Add a folder or terminal workspace")
        .accessibilityLabel("Add workspace")
    }

    /// A folder chip is a menu offering "Create Terminal" and "Detach"; a terminal chip shows a
    /// terminal icon with a detach button (detaching a terminal also tears down its live session).
    @ViewBuilder
    private func chip(for workspace: WorkspaceModel) -> some View {
        switch workspace.kind {
        case .folder:
            Menu {
                Button {
                    confirmCreateTerminal(from: workspace)
                } label: {
                    Label("Create Terminal", systemImage: "terminal")
                }
                .help("Create a terminal workspace rooted at \(workspace.displayName)")
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

    private func attachWorkspace(at url: URL) {
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
    }

    private func pickFolderForTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Start Folder"
        panel.message = "Choose the folder where the terminal should start."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmTerminalCreation(folderDescription: url.lastPathComponent) else { return }
        _ = try? WorkspaceAttachmentSupport.attachTerminal(
            to: conversation,
            fromFolderURL: url,
            modelContext: modelContext
        )
    }

    private func confirmCreateTerminal(from folder: WorkspaceModel) {
        guard confirmTerminalCreation(folderDescription: folder.displayName) else { return }
        WorkspaceAttachmentSupport.attachTerminal(to: conversation, fromFolder: folder, modelContext: modelContext)
    }

    private func confirmTerminalCreation(folderDescription: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Create Terminal Workspace?"
        alert.informativeText = """
        The shell will start in \(folderDescription), but it is not jailed to that folder. Each command stays approval-gated unless you allow this terminal for the session.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create Terminal")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
