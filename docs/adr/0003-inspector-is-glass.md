# The inspector is glass; conversations own their setup

The inspector shows only what the prompt pipeline did for a turn. It holds no settings and
has no Compose mode. Conversation settings (operator, workspaces, tools) live in the
conversation's toolbar as menu buttons that show their current state; the app-wide model
gets a toolbar indicator that says it is global; operator identity and vault live in an
operator window. Selecting an operator opens its home conversation in the same `ChatView`
as every other conversation.

We chose this because configuration in the inspector vanished as soon as a message was
sent (sending selects the new turn, which switched the inspector to Inspect), and because
the same settings had grown three or four entry points. Full design:
[docs/design/interaction-paradigm.md](../design/interaction-paradigm.md).

## Considered options

- **Compose as a sixth inspector tab**: rejected — settings would stay hidden behind the
  inspector and would compete with the per-turn tabs.
- **A settings strip above the transcript**: rejected — it costs vertical space in every
  conversation to repeat what toolbar buttons can show.
- **Keep the operator page (Chat/Vault/Settings tabs) as the selection target**: rejected —
  it nests a second title and tab bar above the chat, or adds a click before chatting.

## Consequences

The custom inspector drawer, `RightPanePresentation`, and `InspectorWidthClamping` go away
in favour of the native `.inspector`. The unused per-operator model and default-tool
controls are removed from the UI; the stored fields stay for a future feature.
