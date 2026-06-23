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
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
    }

    private func detachWorkspace() {
        WorkspaceAttachmentSupport.detachWorkspace(from: conversation, modelContext: modelContext)
    }
}

enum WorkspaceAttachmentSupport {
    static let filesystemToolIds = ["cat", "ls", "find", "search_files", "grep", "change_directory"]

    static var defaultDocumentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    @discardableResult
    static func attachWorkspace(to conversation: ConversationModel, modelContext: ModelContext, url: URL) -> WorkspaceModel {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        let workspace = WorkspaceModel(displayName: url.lastPathComponent, folderPath: url.path, bookmarkData: bookmark)
        modelContext.insert(workspace)
        conversation.workspaceId = workspace.id

        var enabledToolIds = Set(conversation.enabledToolIds)
        enabledToolIds.formUnion(filesystemToolIds)
        conversation.enabledToolIds = Array(enabledToolIds)

        try? modelContext.save()
        return workspace
    }

    static func detachWorkspace(from conversation: ConversationModel, modelContext: ModelContext) {
        conversation.workspaceId = nil
        conversation.enabledToolIds.removeAll { filesystemToolIds.contains($0) }
        try? modelContext.save()
    }
}
