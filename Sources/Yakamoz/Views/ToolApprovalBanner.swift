import SwiftUI
import YakamozCore

/// Inline prompt shown while the agent is blocked awaiting approval for a permissioned tool call
/// (YAK-31). Renders the oldest pending request from the `MainActorToolApprover` — the filesystem
/// tools `read_file`/`ls`/`find`/`search_files`/`grep` — and lets the user Approve or Deny it. The
/// agent stays suspended until one of these resolves the request. This is the tool-call analogue of
/// `TerminalApprovalBanner`; `terminal_run` keeps its own banner and is auto-approved by this gate.
struct ToolApprovalBanner: View {
    let approver: MainActorToolApprover

    var body: some View {
        if let pending = approver.oldestPending {
            VStack(alignment: .leading, spacing: 8) {
                Label("Tool needs approval", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(pending.toolName)  ·  \(pending.argumentSummary)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button("Deny", role: .cancel) {
                        approver.deny(pending)
                    }
                    .accessibilityLabel("Deny tool call")

                    Spacer()

                    Button("Approve") {
                        approver.approve(pending)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve tool call")
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.yellow.opacity(0.5)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
