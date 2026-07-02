import MarkdownUI
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
    let onRetry: (UUID) -> Void

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

        case let .error(id, message, retryPrompt):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if let prompt = retryPrompt, !prompt.isEmpty {
                    Button("Retry") {
                        onRetry(id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Retry failed turn")
                }
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
    @State private var isThinkingExpanded: Bool = true

    /// STAB-9: MarkdownUI re-parses the *entire* accumulated response on every body
    /// re-evaluation. During streaming the body re-renders per token (the view model
    /// rewrites the assistant transcript item in place on each delta), so a response of
    /// N tokens costs O(N²) markdown parsing — visibly laggy on long streams.
    ///
    /// We break that quadratic by snapshotting the streamed text into
    /// `streamingMarkdownText` at most every `streamingMarkdownCoalesceInterval`
    /// (~200ms) while `!turn.isComplete`, so `Markdown` only re-parses on that cadence
    /// (a plain `Text` in between would drop code blocks/lists/tables/bold, which is
    /// too much to lose on markdown-heavy streams). Once the turn completes,
    /// `markdownSource` returns the live `reconstructedText` directly, so the finished
    /// render is byte-identical to the pre-STAB-9 render — no visual change after
    /// completion.
    @State private var streamingMarkdownText: String = ""
    @State private var lastMarkdownRenderAt: Date = .distantPast
    private static let streamingMarkdownCoalesceInterval: TimeInterval = 0.2

    private var thinkingContent: String {
        turn.response.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text `Markdown` should parse right now. Once the turn is complete this is the
    /// full `reconstructedText` (final, exact render). While streaming it is the
    /// throttled `streamingMarkdownText` snapshot — except before the first snapshot
    /// exists, where it falls back to the live text so the first token renders
    /// immediately instead of blanking for ~200ms.
    private var markdownSource: String {
        if turn.isComplete { return turn.response.reconstructedText }
        return streamingMarkdownText.isEmpty ? turn.response.reconstructedText : streamingMarkdownText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reasoning usually precedes the answer, so render the thinking disclosure
            // above the assistant text. Bound to `turn.response.thinking` so it
            // live-updates during streaming and survives reload (STAB-2).
            if !thinkingContent.isEmpty {
                DisclosureGroup(isExpanded: $isThinkingExpanded) {
                    Text(turn.response.thinking)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.secondary)
                        Text("Thinking")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if !turn.isComplete {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }
                .accessibilityLabel("Reasoning trace")
            }

            if !markdownSource.isEmpty {
                // MarkdownUI renders full GFM (tables, nested lists, code blocks, thematic
                // breaks) as real SwiftUI views — a single `AttributedString`-backed `Text`
                // cannot express tables and drops block separators. STAB-9: `markdownSource`
                // is the throttled snapshot while streaming, the live text once complete.
                Markdown(markdownSource)
                    .textSelection(.enabled)
            } else if turn.isCancelled {
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            } else if !turn.isComplete && thinkingContent.isEmpty {
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
        .onChange(of: turn.response.reconstructedText) { _, newText in
            // STAB-9: coalesce Markdown re-parses during streaming. `lastMarkdownRenderAt`
            // starts at `.distantPast` so the first non-empty delta snapshots immediately
            // (no ~200ms blank gap); subsequent deltas are batched onto a ~200ms cadence.
            // Completion is handled by `markdownSource` returning the live
            // `reconstructedText` directly, not here.
            guard !turn.isComplete, !newText.isEmpty else { return }
            let now = Date()
            if now.timeIntervalSince(lastMarkdownRenderAt) >= Self.streamingMarkdownCoalesceInterval {
                streamingMarkdownText = newText
                lastMarkdownRenderAt = now
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
            if let arguments = trace.arguments, !arguments.isEmpty {
                Text("(\(Self.snippet(arguments, limit: 80)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let result = trace.resultSummary {
                Text("-> \(Self.snippet(result, limit: 100))")
                    .font(.caption.monospaced())
                    .foregroundStyle(trace.state == .failed ? .red : .secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "..."
    }
}

private extension ToolTrace {
    var resultSummary: String? {
        if let error, !error.isEmpty {
            return error
        }
        if let output, !output.isEmpty {
            return output
        }
        return nil
    }
}
