# YAK-20 — Turn-selection indicator overpowers the message bubbles

- **Status:** Done
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

When an assistant message is selected (to drive the inspector), the selection styling is
too heavy — it visually dominates the message content rather than acting as a subtle
indicator.

## Proposed approach
- Tone down the selected-state styling in `MessageBubble` (e.g. a thin accent border or a
  faint background tint / leading accent bar instead of a strong fill/outline). Keep it
  clearly distinguishable but secondary to the message text.
- Ensure it reads well in both light and dark appearance and doesn't reduce text contrast.

## Acceptance criteria
- Selected message is identifiable but the indicator no longer overpowers the bubble.
- Looks correct in light + dark mode.

## Pointers
- `Sources/Yakamoz/Views/MessageBubble.swift` (`isSelected` styling)
- `Sources/Yakamoz/Views/ChatView.swift` (`isSelected(_:viewModel:)`, `onSelectTurn`)
