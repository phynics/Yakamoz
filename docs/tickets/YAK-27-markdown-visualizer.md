# YAK-27 — Integrate a Markdown visualizer for assistant responses

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** product follow-up (2026-06-25)

## Problem

Assistant responses are currently rendered as plain text, so Markdown structure from
models is hard to scan. Lists, headings, inline code, links, and code fences appear as
raw Markdown instead of readable formatted content. This makes longer responses and
tool-assisted explanations feel lower quality than the model output actually is.

## Task

- Add Markdown rendering for assistant response text in the chat transcript.
- Keep user messages, tool call indicators, cancellation/thinking states, and turn
  selection behavior unchanged.
- Preserve text selection where feasible, especially for code and normal prose.
- Decide whether the first implementation should be a lightweight native renderer or
  a richer package-backed Markdown view.

## Rendering options to evaluate

1. **SwiftUI `AttributedString(markdown:)` / `Text(AttributedString)`**
   - Best default candidate because it avoids a dependency and should cover common
     inline Markdown plus simple block formatting.
   - Risks: limited control over code block layout, tables, task lists, syntax
     highlighting, and some GitHub-flavored Markdown features.

2. **Package-backed SwiftUI Markdown renderer**
   - Candidates include `MarkdownUI` or a similar maintained Swift package.
   - Better for block layout, code fences, tables, themes, and future polish.
   - Risks: dependency footprint, styling integration, and package trust/release
     maintenance.

3. **WebView-backed renderer**
   - Most compatible with GitHub-flavored Markdown if paired with a JS/HTML renderer.
   - Likely too heavy for chat bubbles and harder to integrate with native selection,
     accessibility, and app styling.
   - Treat as a fallback only if native/package options fail important requirements.

## Acceptance criteria

- Assistant messages render common Markdown: paragraphs, emphasis, headings, lists,
  links, inline code, and fenced code blocks.
- Plain text responses render identically or near-identically to today.
- Streaming updates do not flicker or break selection/turn selection.
- Tool trace rows remain visually separate from rendered assistant text.
- Links are visibly distinct and either open safely or have a deliberate disabled
  behavior.
- Add focused tests around the Markdown rendering/projection boundary where practical;
  at minimum, cover parser/fallback behavior outside of purely visual SwiftUI layout.
- `make verify` is green in Yakamoz.

## Pointers

- `Sources/Yakamoz/Views/MessageBubble.swift`
- `Sources/YakamozCore/Chat/ChatViewModel.swift`
- `Tests/YakamozTests/ChatViewModelTests.swift`
- `Tests/YakamozTests/ChatEventReducerTests.swift`
