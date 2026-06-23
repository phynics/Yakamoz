import SwiftUI

/// Multiline message composer: Return sends, Shift-Return inserts a newline. The
/// trailing button doubles as send/stop, bound to `isSending`.
struct ComposerView: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    /// Bumped by the parent (after a send, or via the composer-focus command) to return
    /// keyboard focus to the text field. Defaults to a constant so callers/previews that
    /// don't manage focus keep working.
    var focusToken: Int = 0

    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 8)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .focused($isComposerFocused)
                .onSubmit(submitFromReturn)
                // SwiftUI's onSubmit fires on plain Return; Shift-Return inserts a
                // newline into the bound text by default for an .vertical axis
                // TextField, so no extra handling is required for the newline case.
                .disabled(isSending)
                .accessibilityLabel("Message composer")
                .onAppear { isComposerFocused = true }
                .onChange(of: focusToken) { _, _ in isComposerFocused = true }

            Button {
                if isSending {
                    onCancel()
                } else {
                    onSend()
                }
            } label: {
                Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!isSending && !canSend)
            .accessibilityLabel(isSending ? "Stop" : "Send")
        }
        .padding(8)
    }

    private func submitFromReturn() {
        guard canSend else { return }
        onSend()
    }
}
