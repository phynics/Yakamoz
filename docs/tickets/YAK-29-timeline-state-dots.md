# YAK-29 — Timeline state dots in the chat list

- **Status:** Done
- **Priority:** Medium
- **Repos:** Yakamoz (+ PositronicKit if the shared timeline model needs a state field)
- **Surfaced by:** product follow-up (2026-06-25)

## Problem

The chat list currently shows conversations as static rows, even though each timeline can
be actively generating, waiting on tools, complete, failed, blocked, or otherwise in a
state that changes how the user should triage it. When several timelines are running or
waiting, the list does not show which ones need attention, which finished cleanly, or
which should drop in priority after reaching a terminal state.

## Task

- Track a user-facing timeline state for each conversation/timeline.
- Render that state as a compact colorful dot in `ConversationListView` rows.
- Update the state from chat lifecycle events, including stream start, tool execution,
  stream completion, cancellation, and error/blocked conditions.
- Sort or otherwise prioritize the list so active/attention-needed timelines stay easy
  to find, while finished or blocked timelines settle appropriately after their terminal
  events.
- Keep the indicator lightweight: the dot should communicate state at a glance without
  overpowering the conversation title or current selection style.

## State model to evaluate

- `idle`: no in-flight turn and no recent terminal event needing attention.
- `running`: a turn is streaming or thinking.
- `tooling`: a tool call is being attempted or is awaiting output.
- `completed`: the most recent turn completed successfully.
- `blocked`: the turn hit a recoverable/user-action-needed condition.
- `failed`: the turn ended with an error.
- `cancelled`: the user cancelled the in-flight turn.

Consider whether this belongs on `ConversationModel` as a Yakamoz-only UI field, on
`TimelineModel` as persisted runtime metadata, or in a separate projection keyed by
timeline id. Prefer a shape that can be derived from `ChatEvent` handling without making
SwiftUI list rows observe a whole `ChatViewModel` for every conversation.

## Acceptance criteria

- Each chat-list row shows a stable dot whose color maps to the conversation's current
  timeline state.
- Sending a prompt moves that conversation to an active state immediately.
- Tool execution events can move the dot to a distinct tooling/working state.
- Normal completion, cancellation, errors, and blocked conditions move the dot to the
  expected terminal state.
- Active or attention-needed timelines are prioritized ahead of quiet completed/idle
  timelines without reintroducing the list jump from YAK-21 for ordinary conversation
  creation.
- The selected row, hover state, and conversation title remain readable with the dot
  present.
- State survives reopening the app if the selected persistence model is durable; if the
  first pass intentionally keeps it ephemeral, document that decision in code or tests.
- Add reducer/projection tests for state transitions from chat events and focused UI
  tests where practical.
- `make verify` is green in Yakamoz; PositronicKit tests/build are green if shared
  timeline state support is added there.

## Pointers

- `Sources/Yakamoz/Views/ConversationListView.swift`
- `Sources/Yakamoz/Views/ChatView.swift`
- `Sources/YakamozCore/Chat/ChatViewModel.swift`
- `Sources/YakamozCore/Chat/ChatEventReducer.swift`
- `Sources/YakamozCore/Models/PersistenceModels.swift`
- `Tests/YakamozTests/ChatEventReducerTests.swift`
- `Tests/YakamozTests/ChatViewModelTests.swift`
- Related: [YAK-21](YAK-21-new-conversation-list-jump.md)

> **Resolved.** Conversations now persist a lightweight `timelineState` plus
> `timelineStateUpdatedAt`, update that state from chat lifecycle events, and render a compact
> colored dot in `ConversationListView`. Active and attention-needed conversations are prioritized
> ahead of quieter terminal states without reintroducing the YAK-21 new-conversation jump.
> Focused verification passed with `make test TEST_FILTER=ChatEventReducerTests` and
> `make test TEST_FILTER=ChatViewModelTests`.
