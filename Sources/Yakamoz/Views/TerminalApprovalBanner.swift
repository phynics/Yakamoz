import SwiftUI
import YakamozCore

/// Inline prompt shown while the agent is blocked awaiting approval for a `terminal_run`
/// command (YAK-T5). Renders the oldest pending request from the `MainActorApprover` and lets
/// the user Approve it, Deny it, or allow this terminal for the rest of the session. The agent
/// stays suspended until one of these resolves the request.
struct TerminalApprovalBanner: View {
    let approver: MainActorApprover
    let workspaceIDs: Set<UUID>

    var body: some View {
        if let pending = approver.pendingApproval(for: workspaceIDs) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Terminal command needs approval", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(pending.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button("Deny", role: .cancel) {
                        approver.resolve(pending, with: .deny)
                    }
                    .accessibilityLabel("Deny command")

                    Spacer()

                    Button("Allow for this terminal") {
                        approver.resolve(pending, with: .allowForSession)
                    }
                    .accessibilityLabel("Allow this terminal for the session")

                    Button("Approve") {
                        approver.resolve(pending, with: .approve)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve command")
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
