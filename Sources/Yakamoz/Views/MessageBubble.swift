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
    let onSelectPromptOption: (UUID, ChatPromptOption) -> Void

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
                            isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(alignment: .leading) {
                            // A thin leading accent bar reads as "selected" without the heavy
                            // fill/outline overpowering the message text (YAK-20).
                            if isSelected {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.accentColor)
                                    .frame(width: 3)
                                    .padding(.vertical, 6)
                                    .padding(.leading, 2)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")
                Spacer(minLength: 40)
            }

        case let .error(_, message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                Spacer(minLength: 40)
            }
            .padding(.vertical, 4)

        case let .prompt(id, prompt):
            HStack {
                ChatPromptRow(prompt: prompt) { option in
                    onSelectPromptOption(id, option)
                }
                Spacer(minLength: 40)
            }
        }
    }
}

private struct ChatPromptRow: View {
    let prompt: ChatPrompt
    let onSelect: (ChatPromptOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.callout.weight(.medium))
                if let detail = prompt.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(prompt.options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(option.title)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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
