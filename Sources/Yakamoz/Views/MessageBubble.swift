import MarkdownUI
import SwiftUI
import YakamozCore

/// Renders a single `TranscriptItem` as a full-width transcript row. Assistant rows
/// remain tappable (`.buttonStyle(.plain)`) to drive `selectedTurnIndex` on the
/// owning `ChatViewModel`, so the inspector can show detail for the tapped turn.
struct MessageBubble: View {
    let item: TranscriptItem
    let isSelected: Bool
    let onSelectTurn: (Int) -> Void
    let onSelectPromptOption: (UUID, ChatPromptOption) -> Void
    let onRetry: (UUID) -> Void

    var body: some View {
        switch item {
        case let .user(_, text, _):
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .user, isSelected: false)) {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .assistant(_, turn):
            let presentation = TranscriptRowPresentation(role: .assistant, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onSelectTurn(turn.turnIndex)
                } label: {
                    TranscriptRowFrame(presentation: presentation) {
                        AssistantTurnContent(turn: turn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")

                ForEach(turn.orderedTools) { trace in
                    ToolTranscriptRow(trace: trace)
                }
            }

        case let .error(id, message, retryPrompt):
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .error, isSelected: false)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                    Spacer(minLength: 0)
                }
            }

        case let .prompt(id, prompt):
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .prompt, isSelected: false)) {
                ChatPromptRow(prompt: prompt) { option in
                    onSelectPromptOption(id, option)
                }
            }
        }
    }
}

private struct TranscriptRowFrame<Content: View>: View {
    let presentation: TranscriptRowPresentation
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(presentation.gutterColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            Image(systemName: presentation.iconSystemName)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(presentation.iconColor)
                .frame(width: 18)
                .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(presentation.selectionColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
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

private struct ToolTranscriptRow: View {
    let trace: ToolTrace
    @State private var isShowingDetail = false

    private var presentation: ToolTranscriptPresentation {
        ToolTranscriptPresentation(trace: trace)
    }

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .tool, isSelected: false)) {
                HStack(spacing: 8) {
                    statusIcon
                    Text(presentation.notation)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tool call \(presentation.notation)")
        .popover(isPresented: $isShowingDetail) {
            ToolTranscriptDetailPopover(presentation: presentation)
                .frame(width: 520, height: 360)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.status {
        case .attempting:
            ProgressView()
                .controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct ToolTranscriptDetailPopover: View {
    let presentation: ToolTranscriptPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "function")
                    .foregroundStyle(.secondary)
                Text(presentation.detailTitle)
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !presentation.fullParameters.isEmpty {
                        labeledBlock("Parameters", text: presentation.fullParameters)
                    }
                    if !presentation.fullResponse.isEmpty {
                        labeledBlock("Response", text: presentation.fullResponse, isError: presentation.status == .failure)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func labeledBlock(_ title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension TranscriptRowPresentation {
    var gutterColor: Color {
        switch gutterAccent {
        case .sea:
            Color.cyan.opacity(0.72)
        case .moon:
            Color.indigo.opacity(0.58)
        case .selectedMoon:
            Color.accentColor
        case .tool:
            Color.orange.opacity(0.72)
        case .error:
            Color.red.opacity(0.82)
        case .neutral:
            Color(nsColor: .separatorColor)
        }
    }

    var iconColor: Color {
        switch role {
        case .user:
            Color.cyan.opacity(0.85)
        case .assistant:
            isSelected ? Color.accentColor : Color.indigo.opacity(0.75)
        case .tool:
            Color.orange.opacity(0.82)
        case .error:
            Color.red
        case .prompt:
            Color.secondary.opacity(0.85)
        }
    }

    var selectionColor: Color {
        selectionTreatment == .subtleTint ? Color.accentColor.opacity(0.055) : Color.clear
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
