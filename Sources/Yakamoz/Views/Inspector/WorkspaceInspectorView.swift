import SwiftUI
import YakamozCore

/// Workspace tab: the folder attached to the conversation (if any) — its name, path,
/// health, the filesystem tools it exposes, and the files the model has touched so far in
/// the selected turn. A **Detach** action clears the conversation's workspace mid-conversation.
///
/// **YAK-17:** this tab no longer renders a file listing — `WorkspacePresentation` stopped
/// enumerating the folder's contents, so there is nothing to project here. Identity
/// (name/path/health) and a Detach action are the essential content.
///
/// **Gap 2 note:** a workspace is attached at the conversation level, not per-turn, so
/// this tab's primary content (`presentation`) is independent of `InspectionViewModel`'s
/// turn-scoped data — it is loaded once per conversation by `ChatView` via
/// `YakamozRuntime.makeWorkspacePresentation(for:)`, which returns the `Sendable`
/// `WorkspacePresentation` value type so this app-target view never imports
/// `WorkspaceProtocol`/`PositronicKit` directly. `touchedFiles` (from the selected turn's
/// `ChatTurnState.workspaceFiles`) is the one piece of genuinely turn-scoped data and is
/// passed in separately.
struct WorkspaceInspectorView: View {
    let presentation: WorkspacePresentation?
    let touchedFiles: [String]
    let onRefresh: () -> Void
    let onAttachDocuments: () -> Void
    let onChooseFolder: () -> Void
    let onDetach: () -> Void

    var body: some View {
        if let presentation {
            content(presentation)
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "No Workspace Attached",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Attach a folder to this conversation to enable filesystem tools.")
                )
                emptyStateActions
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ presentation: WorkspacePresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(presentation)
                toolsSection(presentation)
                if !touchedFiles.isEmpty {
                    touchedFilesSection
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ presentation: WorkspacePresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(presentation.displayName).font(.callout.weight(.semibold))
                Spacer()
                healthBadge(presentation.isHealthy)
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh workspace")
                .accessibilityLabel("Refresh workspace")
                Button {
                    onDetach()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Detach workspace")
                .accessibilityLabel("Detach workspace")
            }
            Text(presentation.folderPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func healthBadge(_ isHealthy: Bool) -> some View {
        Text(isHealthy ? "Healthy" : "Unavailable")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isHealthy ? Color.green : Color.red).opacity(0.15), in: Capsule())
            .foregroundStyle(isHealthy ? .green : .red)
            .accessibilityLabel(isHealthy ? "Workspace healthy" : "Workspace unavailable")
    }

    private func toolsSection(_ presentation: WorkspacePresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if presentation.toolNames.isEmpty {
                Text("No tools available").font(.caption).foregroundStyle(.secondary)
            } else {
                FlowText(items: presentation.toolNames)
            }
        }
    }

    private var touchedFilesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files Touched This Turn").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(touchedFiles, id: \.self) { file in
                Text(file)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var emptyStateActions: some View {
        VStack(spacing: 8) {
            Button("Attach Documents", action: onAttachDocuments)
            Button("Choose Folder", action: onChooseFolder)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// A simple wrapping chip row for a list of short string labels (tool names).
private struct FlowText: View {
    let items: [String]

    var body: some View {
        // macOS-friendly wrap: a simple HStack-of-chips inside a flexible LazyVGrid keeps
        // this dependency-free; the inspector drawer is narrow enough that a vertical
        // list reads just as well and avoids a custom flow-layout implementation.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }
}
