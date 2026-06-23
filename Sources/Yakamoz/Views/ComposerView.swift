import SwiftUI

/// Multiline message composer: Return sends, Shift-Return inserts a newline. The
/// trailing button doubles as send/stop, bound to `isSending`.
struct ComposerView: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

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
                .onSubmit(submitFromReturn)
                // SwiftUI's onSubmit fires on plain Return; Shift-Return inserts a
                // newline into the bound text by default for an .vertical axis
                // TextField, so no extra handling is required for the newline case.
                .disabled(isSending)

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
