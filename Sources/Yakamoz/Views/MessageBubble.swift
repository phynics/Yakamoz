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
                if let entries = TurnTranscriptProjection.indexedSegments(for: turn) {
                    // UIX-7: thinking segments render as their own disclosure at their
                    // chronological position (not folded into AssistantTurnContent), so
                    // `isFirstTextSegment`/`isLastTextSegment` below are computed over the
                    // *text*-only subsequence — thinking segments don't participate in the
                    // streaming-markdown-placeholder bookkeeping AssistantTurnContent does.
                    let textIndices: [Int] = entries.indices.filter { if case .text = entries[$0].segment { true } else { false } }
                    // UIX-17: use the segment's original `turnSegments` index (stable,
                    // append-only) as the ForEach id instead of the filtered array offset,
                    // which could shift when a previously-filtered segment becomes non-empty
                    // and cause SwiftUI to diff mismatched view types → crash.
                    ForEach(entries, id: \.index) { entry in
                        let index = entry.index
                        let segment = entry.segment
                        switch segment {
                        case let .text(text):
                            Button {
                                onSelectTurn(turn.turnIndex)
                            } label: {
                                TranscriptRowFrame(presentation: presentation) {
                                    AssistantTurnContent(
                                        turn: turn,
                                        segmentText: text,
                                        isFirstSegment: index == textIndices.first,
                                        isLastSegment: index == textIndices.last
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Assistant turn \(turn.turnIndex + 1)")

                        case let .tool(trace):
                            ToolTranscriptRow(trace: trace)

                        case let .thinking(thought, isStreaming):
                            // UIX-9: `isStreaming` already reflects "is this the turn's
                            // trailing segment and the turn incomplete" per-segment, computed
                            // by `TurnTranscriptProjection` from `turn.turnSegments` position +
                            // `turn.isComplete` — an earlier thinking segment reports `false`
                            // once anything follows it, even mid-turn.
                            ThinkingSegmentRow(thought: thought, isStreaming: isStreaming)
                        }
                    }
                    // A turn that is still streaming its very first thinking tokens has no
                    // segments yet at all (the first delta is what creates one) — but the
                    // legacy fallback below only applies when `turnSegments` is entirely
                    // empty, which is exactly that case too, so no separate placeholder is
                    // needed here.
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

        case let .system(_, text, _):
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .system, isSelected: false)) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// UIX-13: renders one chronologically-positioned thinking segment. Replaces the UIX-7/
/// UIX-9 `DisclosureGroup` entirely — there is no expand/collapse interaction anymore:
///
/// - **While streaming:** a compact "Thinking" label + spinner, with a fixed-height
///   (three-line) viewport underneath showing the live tail of the reasoning text,
///   bottom-anchored and gradient-masked at the top edge. Because the viewport height
///   never changes and the text is bottom-aligned inside it, new lines "slide up" through
///   a stable window as deltas arrive instead of the visible slice being recomputed from
///   a character count each time (UIX-11's approach) — that's what removes the reflow
///   jitter the ticket calls out.
/// - **Once finished:** the tail viewport disappears; the row is just the compact
///   one-line "Thinking" marker.
/// - **Click anywhere on the row** opens the full-text popover (`ThinkingDetailPopover`),
///   for every thinking row regardless of length — no more `needsPopover` length gate.
///
/// Not wrapped in the turn-select button (mirrors tool rows, UIX-3): a thinking-row click
/// opens its own popover and must never also select the turn.
private struct ThinkingSegmentRow: View {
    let thought: String
    /// Whether this is the currently-growing trailing segment of an in-progress turn.
    /// Drives both the streaming spinner and whether the masked tail viewport renders at
    /// all (`true` while streaming, gone once the segment completes).
    let isStreaming: Bool
    /// Whether the full-text popover is currently shown. Tapping the row (label or tail)
    /// opens it; mirrors the tool-row popover pattern (UIX-3).
    @State private var isShowingDetail = false

    /// UIX-13: presentation now just carries `fullText` (for the popover) and
    /// `isStreaming` (which still decides tail-vs-marker) — see the type's doc comment
    /// for why the head/tail slicing and popover-length-gate logic it used to own moved
    /// out (superseding UIX-9/UIX-11).
    private var presentation: ThinkingSegmentPresentation {
        ThinkingSegmentPresentation(thought: thought, isStreaming: isStreaming)
    }

    var body: some View {
        // Rendered inside the shared `TranscriptRowFrame` (gutter + role icon) so thinking
        // rows read as part of the same visual system as user/assistant/tool rows — the
        // frame's `.thinking` role supplies the brain icon.
        Button {
            isShowingDetail = true
        } label: {
            TranscriptRowFrame(presentation: TranscriptRowPresentation(role: .thinking, isSelected: false)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Thinking")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer(minLength: 0)
                    }

                    if isStreaming {
                        ThinkingTailView(text: presentation.fullText)
                            // UIX-13/UIX-8: the tail viewport is fixed-height regardless
                            // of how many lines of text back it — the one height change
                            // left is this view disappearing entirely at segment end,
                            // which coincides with new-content arrival (a following
                            // segment appears, or the turn completes) — the same event
                            // that already retriggers `ChatView`'s pinned mid-stream
                            // follow via `ScrollFollowPresentation.streamingGrowthMetric`.
                            .transition(.opacity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingDetail) {
            ThinkingDetailPopover(fullText: presentation.fullText)
                .frame(minWidth: 280, idealWidth: 520, maxWidth: 520, maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: isStreaming)
        .accessibilityLabel("Reasoning trace")
    }
}

/// UIX-13: fixed-height, bottom-anchored, top-gradient-masked "ticker" viewport onto the
/// live tail of a streaming thinking segment. Deliberately layout-based rather than
/// string-slicing (UIX-11's approach, which reflowed/jittered on every delta): the text
/// is rendered in full inside a fixed-height clipping container, bottom-aligned, so as new
/// characters/lines are appended the already-visible lines simply shift up within a stable
/// window — nothing about the *visible* slice is recomputed from a character count.
private struct ThinkingTailView: View {
    let text: String

    /// Three lines tall (per the ticket's revised "three-line tail" direction), sized off
    /// the caption-monospaced font actually rendered below so the mask lines up with real
    /// line boxes rather than a guessed constant.
    private var viewportHeight: CGFloat {
        let lineHeight = Font.TextStyle.caption.lineHeightApproximation
        return lineHeight * 3
    }

    var body: some View {
        // `.fixedSize(horizontal: false, vertical: true)` is the key: it makes the
        // Text take its full intrinsic height regardless of the height proposal from
        // `.frame(height: viewportHeight)` below. Without it, SwiftUI may position
        // the Text from the top of the viewport (showing the head) instead of the
        // bottom (showing the tail). With it, the full-height Text is bottom-aligned
        // within the fixed viewport, and `.clipped()` crops the overflowing head.
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: viewportHeight, alignment: .bottom)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.35),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private extension Font.TextStyle {
    /// Rough point-size-based line-height approximation for sizing the fixed tail
    /// viewport. Not pixel-exact (the real line height depends on the resolved system
    /// font metrics), but stable and proportionate — good enough for a mask boundary,
    /// where a few points of slop is invisible next to the gradient fade.
    var lineHeightApproximation: CGFloat {
        switch self {
        case .caption: 14
        default: 16
        }
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
                // UIX-10: the chat row carries only the human framing — status glyph +
                // `rowTitle` (the TEX-2 explanation, or the bare tool name when no
                // explanation is available). The mechanical fx notation
                // (`name(args) -> result`) no longer renders inline; it moved into the
                // popover below, alongside the existing Parameters/Response blocks.
                HStack(spacing: 8) {
                    statusIcon
                    Text(presentation.rowTitle)
                        .font(presentation.rowTitleIsFallbackName ? .system(.callout, design: .monospaced) : .caption)
                        .foregroundStyle(presentation.rowTitleIsFallbackName ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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

    private var accessibilityLabel: String {
        // UIX-10: meaningful label built from `rowTitle` (explanation or name), never the
        // raw fx notation/arguments.
        if presentation.rowTitleIsFallbackName {
            return "Tool call \(presentation.rowTitle)"
        }
        return "\(presentation.rowTitle). Tool call"
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
                    // UIX-10: the fx notation one-liner (`name(args) -> result`) now lives
                    // only here — it was removed from the inline chat row, which shows just
                    // the status glyph + explanation/name.
                    Text(presentation.notation)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

/// UIX-11: popover reached only when a thinking segment's text exceeds
/// `ThinkingSegmentPresentation.defaultThreshold` — mirrors `ToolTranscriptDetailPopover`'s
/// sizing/scrolling/copy pattern (monospaced, scrollable, `.textSelection(.enabled)`,
/// sized-to-content with caps) so the two popover surfaces feel like one system.
private struct ThinkingDetailPopover: View {
    let fullText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.secondary)
                Text("Thinking")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                Text(fullText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }
}

private extension TranscriptRowPresentation {
    var gutterColor: Color {
        switch gutterAccent {
        case .sea:
            Color.cyan.opacity(0.72)
        case .moon:
            // Turquoise for assistant rows; the indigo/purple moved to `.reverie`
            // (thinking) — user direction 2026-07-05.
            Color.teal.opacity(0.72)
        case .selectedMoon:
            Color.accentColor
        case .reverie:
            Color.indigo.opacity(0.58)
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
            isSelected ? Color.accentColor : Color.teal.opacity(0.85)
        case .thinking:
            Color.indigo.opacity(0.75)
        case .tool:
            Color.orange.opacity(0.82)
        case .error:
            Color.red
        case .prompt, .system:
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
    /// UIX-9: this disclosure only renders on the legacy fallback path (`segmentText ==
    /// nil` — no `turnSegments` recorded, e.g. a turn reloaded from persistence per
    /// STAB-3). Reloaded turns are records, not live streams, so they default collapsed
    /// rather than the previous always-expanded default; the user can still expand.
    @State private var isThinkingExpanded: Bool = false

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
            // live-updates during streaming and survives reload (STAB-2). Only in the
            // legacy fallback path (`segmentText == nil`, no `turnSegments` recorded —
            // e.g. a reloaded turn, STAB-3): once a turn has `turnSegments`, each
            // `.thinking` segment renders its own disclosure at its chronological
            // position via `ThinkingSegmentRow` (UIX-7) instead of this single
            // first-segment-only block, so it isn't duplicated here.
            if segmentText == nil, isFirstSegment, !thinkingContent.isEmpty {
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
            } else if segmentText == nil, isFirstSegment, !turn.isComplete, thinkingContent.isEmpty {
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
