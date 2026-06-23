import SwiftUI
import YakamozCore

/// Renders a single `TranscriptItem`. User/assistant/error roles are styled distinctly;
/// assistant bubbles are tappable (`.buttonStyle(.plain)`) to drive `selectedTurnIndex`
/// on the owning `ChatViewModel`, so the inspector (Task 8) can show detail for the
/// tapped turn.
struct MessageBubble: View {
    let item: TranscriptItem
    let isSelected: Bool
    let onSelectTurn: (Int) -> Void

    var body: some View {
        switch item {
        case let .user(_, text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }

        case let .assistant(_, turn):
            HStack {
                Button {
                    onSelectTurn(turn.turnIndex)
                } label: {
                    AssistantTurnContent(turn: turn)
                        .padding(10)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")
                Spacer(minLength: 40)
            }

        case let .error(_, message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            }
        }
    }
}

private struct AssistantTurnContent: View {
    let turn: ChatTurnState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turn.response.reconstructedText.isEmpty {
                Text(turn.response.reconstructedText)
                    .textSelection(.enabled)
            } else if turn.isCancelled {
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            } else if let errorMessage = turn.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if !turn.isComplete {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(turn.orderedTools) { trace in
                ToolTraceRow(trace: trace)
            }
        }
    }
}

private struct ToolTraceRow: View {
    let trace: ToolTrace

    var body: some View {
        HStack(spacing: 6) {
            switch trace.state {
            case .attempting:
                ProgressView()
                    .controlSize(.mini)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            Text(trace.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
