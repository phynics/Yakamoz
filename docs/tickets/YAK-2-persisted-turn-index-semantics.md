# YAK-2 — Verify persisted-turn-index vs view-model turn selection

- **Status:** Open
- **Priority:** High
- **Repos:** Yakamoz
- **Surfaced by:** CP11 / Task 11 (E2E test fixes)

## Problem

A single `ChatViewModel` user send can drive **several** engine LLM round-trips
(one per tool-resolution loop). Each round-trip fires `TurnInspecting.didComposeTurn`,
so it creates its **own** persisted `TurnInspectionModel` row (turnIndex 0, 1, …).
But `ChatViewModel` tracks **one logical turn per send** for transcript/selection
(`nextTurnIndex`, `selectedTurnIndex`).

CP11 reconciled the response/tool-trace write by persisting to the engine's *latest*
row (`SwiftDataTurnInspector.updateLatestResponse` / `latestTurnIndex`). That makes
the E2E assertions pass, but it leaves a **semantic mismatch worth verifying**:

- The inspector drawer loads by `(conversationId, turnIndex)` using the view model's
  `selectedTurnIndex`. For a multi-round-trip send, which persisted row does the user
  actually see when they tap the assistant bubble? Does the bubble's `turnIndex` line
  up with the row that has the response/tool data?
- Could selection ever point at a row that exists in persistence but not in the
  transcript (or vice versa), especially after reload?

## Task

Audit and add tests for the mapping between (a) transcript assistant bubbles /
`selectedTurnIndex`, (b) the persisted `TurnInspectionModel` rows per send, and
(c) which row `InspectionViewModel.select` loads. Confirm the user always inspects
the row carrying the response + tool traces for the turn they tapped, including a
multi-tool-loop send and after reopening the conversation. Fix any off-by-one /
mismatched-index cases.

## Pointers
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`consume`, `nextTurnIndex`, `persistResponse`)
- `Sources/YakamozCore/Inspection/SwiftDataTurnInspector.swift` (`latestTurnIndex`, `updateLatestResponse`)
- `Sources/YakamozCore/Inspection/InspectionViewModel.swift` (`select`)
- `Tests/YakamozTests/InspectableChatIntegrationTests.swift`
