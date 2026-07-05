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
                // UIX-4: interleave tool rows between the text segments they actually
                // occurred between, using `turn.turnSegments` chronology captured by
                // `ChatEventReducer`. Each text segment stays wrapped in its own
                // selectable frame/button (mirroring the pre-UIX-4 single-frame
                // behavior) so `onSelectTurn` keeps working from any text segment; tool
                // rows render between them, outside the button, matching the existing
                // tool-row tap semantics (UIX-3: a tool tap must not select the turn).
                // Reloaded turns don't restore tool traces (STAB-3) and record no
                // `turnSegments`, so `TurnTranscriptProjection` returns `nil` and this
                // falls back to the legacy whole-text-then-all-tools rendering.
                if let segments = TurnTranscriptProjection.segments(for: turn) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        switch segment {
                        case let .text(text):
                            Button {
                                onSelectTurn(turn.turnIndex)
                            } label: {
                                TranscriptRowFrame(presentation: presentation) {
                                    AssistantTurnContent(
                                        turn: turn,
                                        segmentText: text,
                                        isFirstSegment: index == 0,
                                        isLastSegment: index == segments.count - 1
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")

                        case let .tool(trace):
                            ToolTranscriptRow(trace: trace)
                        }
                    }
                } else {
                    Button {
                        onSelectTurn(turn.turnIndex)
                    } label: {
                        TranscriptRowFrame(presentation: presentation) {
                            AssistantTurnContent(turn: turn, segmentText: nil, isFirstSegment: true, isLastSegment: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")

                    ForEach(turn.orderedTools) { trace in
                        ToolTranscriptRow(trace: trace)
                    }
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

/// UIX-3 decision: tapping a tool row opens its detail popover only — it deliberately does
/// NOT call `onSelectTurn`/select the owning turn, unlike the assistant bubble button above
/// it. Selection is the Compose/Inspect mode driver (`RightPanePresentation.mode`), so
/// making a tool-row tap also select the turn would force-switch the inspector into Inspect
/// mode as a side effect of what's meant to be a lightweight, transient detail lookup.
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
            // UIX-2 review fix #6: was hard-coded to `.frame(width: 520, height: 360)`
            // regardless of content, so a one-line result got a mostly-empty 360pt-tall
            // popover. Size to content instead — `minWidth` keeps short content from looking
            // cramped, `maxWidth`/`maxHeight` cap it (long content still scrolls inside the
            // popover's own `ScrollView`).
            ToolTranscriptDetailPopover(presentation: presentation)
                .frame(minWidth: 280, idealWidth: 520, maxWidth: 520, maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
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
    /// UIX-4: the specific text segment this instance renders, when the turn was
    /// projected into ordered segments by `TurnTranscriptProjection`. `nil` in the
    /// legacy fallback path (no `turnSegments` recorded — e.g. a reloaded turn, STAB-3),
    /// in which case this renders the full `reconstructedText` exactly as before.
    let segmentText: String?
    /// Whether this is the first rendered segment of the turn — only the first segment
    /// shows the thinking disclosure and the "Thinking…" placeholder, so those don't
    /// repeat once a turn has multiple text segments interleaved with tool rows.
    let isFirstSegment: Bool
    /// Whether this is the last rendered segment — only the last (and, pre-UIX-4, only)
    /// segment can still be actively streaming into, so only it applies the STAB-9
    /// throttled re-parse behavior below.
    let isLastSegment: Bool
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
    /// `markdownSource` returns the live text directly, so the finished render is
    /// byte-identical to the pre-STAB-9 render — no visual change after completion.
    /// UIX-4: this throttling only applies to the last segment, the only one that can
    /// still be growing mid-stream — earlier segments are already-finalized text that
    /// preceded a tool call, so they render their exact content immediately.
    @State private var streamingMarkdownText: String = ""
    @State private var lastMarkdownRenderAt: Date = .distantPast
    private static let streamingMarkdownCoalesceInterval: TimeInterval = 0.2

    private var thinkingContent: String {
        turn.response.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full text this instance is responsible for (either the projected segment, or
    /// the whole `reconstructedText` in the legacy fallback path).
    private var fullSegmentText: String {
        segmentText ?? turn.response.reconstructedText
    }

    /// The text `Markdown` should parse right now. Once the turn is complete, or this
    /// isn't the last segment, this is `fullSegmentText` directly (final, exact render).
    /// While streaming the last segment it is the throttled `streamingMarkdownText`
    /// snapshot — except before the first snapshot exists, where it falls back to the
    /// live text so the first token renders immediately instead of blanking for ~200ms.
    private var markdownSource: String {
        if turn.isComplete || !isLastSegment { return fullSegmentText }
        return streamingMarkdownText.isEmpty ? fullSegmentText : streamingMarkdownText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Reasoning usually precedes the answer, so render the thinking disclosure
            // above the assistant text. Bound to `turn.response.thinking` so it
            // live-updates during streaming and survives reload (STAB-2). Only the
            // first segment shows this — later segments are additional text chunks
            // within the same turn.
            if isFirstSegment, !thinkingContent.isEmpty {
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
                // is the throttled snapshot while streaming the last segment, the exact
                // text otherwise.
                Markdown(markdownSource)
                    .textSelection(.enabled)
            } else if isFirstSegment, turn.isCancelled {
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            } else if isFirstSegment, !turn.isComplete, thinkingContent.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: turn.response.reconstructedText) { _, _ in
            // STAB-9: coalesce Markdown re-parses during streaming. `lastMarkdownRenderAt`
            // starts at `.distantPast` so the first non-empty delta snapshots immediately
            // (no ~200ms blank gap); subsequent deltas are batched onto a ~200ms cadence.
            // Completion is handled by `markdownSource` returning the exact text directly,
            // not here. Only the last segment tracks the live-growing text.
            guard isLastSegment, !turn.isComplete, !fullSegmentText.isEmpty else { return }
            let now = Date()
            if now.timeIntervalSince(lastMarkdownRenderAt) >= Self.streamingMarkdownCoalesceInterval {
                streamingMarkdownText = fullSegmentText
                lastMarkdownRenderAt = now
            }
        }
    }
}
