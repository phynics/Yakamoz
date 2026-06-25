# YAK-24 — Surface empty model responses instead of a silent blank bubble

- **Status:** Open
- **Priority:** High
- **Repos:** Yakamoz
- **Surfaced by:** YAK-23 diagnosis (DeepSeek v4 Flash returns empty when tools are advertised)

## Problem

When the model returns a completely empty completion (no content, no tool call), the user
gets a silent blank assistant bubble with no explanation. Confirmed live with
`deepseek/deepseek-v4-flash` via OpenRouter: with tools advertised it returns
`yieldedAnything=false` / `assistant content chars=0`, and the UI just shows an empty
bubble — indistinguishable from a hang or a bug. This is provider-agnostic: any empty
completion should be made visible.

## Proposed approach

In `ChatViewModel.consume`, after a turn completes normally
(`!isCancelled && errorMessage == nil`), detect the case where the turn produced **no
visible content, no thinking, and no tool traces** and surface it explicitly instead of
leaving an empty assistant bubble — e.g. an inline notice "The model returned an empty
response." (optionally with a hint: "If you have tools enabled, this model may not support
tool calling — try a tool-capable model."). Reuse `ChatTurnState.hasVisibleTranscriptContent`
(already used by `finalizeFailedTurn`) to make the decision.

Optionally include the advertised-tools hint only when `tools` was non-empty, since the
most common trigger is a non-tool-capable model choking on a `tools` array.

## Acceptance criteria
- A turn that completes with no content / no tool calls shows a clear, non-spinning
  message instead of a blank bubble.
- A normal non-empty reply is unaffected.
- Headless test: drive a `ChatViewModel` turn whose stream yields nothing and assert the
  transcript ends in the empty-response notice (not a blank/incomplete assistant item).

## Pointers
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`consume`, `finalizeFailedTurn`, `hasVisibleTranscriptContent`)
- `Sources/YakamozCore/Chat/ChatEventReducer.swift` (`ChatTurnState`)
- `Sources/Yakamoz/Views/MessageBubble.swift` (`AssistantTurnContent` empty/complete rendering)
- Related: [YAK-23](YAK-23-tool-followup-turn-hangs.md)
