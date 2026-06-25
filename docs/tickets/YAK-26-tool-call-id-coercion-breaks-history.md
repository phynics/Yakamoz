# YAK-26 — [BUG] Tool-call id coercion breaks a conversation's next turn (HTTP 400)

- **Status:** Open
- **Priority:** High
- **Repos:** PositronicKit (core) + (observed in) Yakamoz
- **Surfaced by:** real-provider testing after YAK-23 fix (2026-06-25)

## Symptom

The first tool-using turn works end to end (model calls `ls`, it executes, turn 2 answers).
But every **subsequent** user message in that conversation fails with:

```
OpenRouter request failed with HTTP 400: ... "No tool output found for function call
0C7E88BD-3A5F-4CC7-9A52-8C88C68019E4." (invalid_request_error, param: input)
```

i.e. the reconstructed history contains an assistant message with a `tool_calls` entry
whose id has **no matching tool-result message**, so OpenAI/Azure rejects the request.
Note the id is a Swift `UUID`, not the provider's `call_…` id.

## Root cause

`ChatEngine`'s `LLMMessage → Message` conversion
(`../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine.swift:417`) does:

```swift
ToolCall(id: UUID(uuidString: toolCall.id) ?? UUID(), name: ..., arguments: ...)
```

`ToolCall.id` is typed `UUID` (`../PositronicKit/Sources/PKShared/SharedTypes/ToolCall.swift:5`),
but provider tool-call ids are arbitrary strings like `call_KrQJZjYow2lgD6yTbqKeqAnT`,
which are **not** valid UUIDs. So:

1. The provider id is discarded.
2. The `?? UUID()` fallback generates a **fresh random UUID every time the conversion
   runs** — including on each history reload for a later turn.

Within a single send the assistant tool_call id and the tool-result `tool_call_id`
happen to match (so turn 1→2 works). But the persisted assistant message stores the
non-UUID provider id, so on the **next** send the conversion produces a *new* random
UUID for the assistant tool_call while the persisted tool-result keeps its original id —
they diverge, and the pairing is lost → HTTP 400.

## Fix options

- **Proper (preferred):** stop coercing. Preserve the provider's tool-call id as a
  `String` (change `ToolCall.id: UUID` → `String`, or add a `providerId: String`), and
  thread it through routing (`ToolRouter`, `call.callId`), persistence, and message
  reconstruction so the assistant tool_call id and tool-result `tool_call_id` are always
  the original provider id. This is the correct model fix but touches several call sites
  and persisted shapes — update Monad/Shuttle/Yakamoz together; keep `make verify` green.
- **Minimal (stopgap):** make the fallback **deterministic** — derive a stable UUID from
  the provider id string (e.g. a UUIDv5/namespaced hash) instead of `UUID()`. Reloads then
  produce the same id, so the pairing survives. Cheaper, but still loses the human-readable
  provider id and is a workaround rather than a fix.

## Acceptance criteria
- A conversation that used a tool can send further messages without HTTP 400.
- Headless test: persist an assistant message with a non-UUID provider tool-call id + its
  tool-result, reload/reconstruct the history twice, and assert the assistant tool_call id
  and tool-result `tool_call_id` still match (and ideally equal the original provider id).
- `make verify` green in PositronicKit; Monad/Shuttle build; Yakamoz `make verify` green.

## Pointers
- `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine.swift:417` (the coercion)
- `../PositronicKit/Sources/PKShared/SharedTypes/ToolCall.swift:5` (`id: UUID`)
- `../PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift:173` (`toolCallId: call.callId`)
- Yakamoz message persistence: `Sources/YakamozCore/Persistence/MessageStore.swift` (envelope round-trip)
- Related: [YAK-23](YAK-23-tool-followup-turn-hangs.md) (the decoder fix that made tools actually run, exposing this)
