# YAK-21 — [BUG] Creating a conversation causes a list jump / reorder

- **Status:** Done
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

Creating a new conversation produces a visible jump: the list reorders and the selection
jumps to the new conversation in a jarring way.

## Likely cause (needs confirmation)

The conversation list `@Query` sort order and the auto-selection of the freshly-created
row aren't animated/stable, so insertion + selection happen as an unanimated reflow. May
also be the timing between `createConversation` persisting the row and the list/selection
updating.

## Proposed approach
- Give the list a stable, explicit sort (e.g. by `createdAt`/`updatedAt` descending) so
  insertion position is predictable.
- Animate the insertion + selection change (`withAnimation`) so the new row appears and is
  selected smoothly rather than snapping.
- Verify selection is set once, after the row exists, to avoid a select-then-reorder
  double movement.

## Acceptance criteria
- Creating a conversation animates in smoothly and selects the new conversation without a
  jarring reorder/jump.

## Pointers
- `Sources/Yakamoz/Views/ConversationListView.swift` (`@Query` sort, selection binding, new-conversation action)
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`createConversation`)
- `Sources/YakamozCore/Runtime/ConversationCoordinator.swift`
