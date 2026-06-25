# YAK-15 — [BUG] Inspector doesn't react to selecting a message until a later turn

- **Status:** Done
- **Priority:** High
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

Clicking an assistant message should load that turn into the inspector. Observed: the
inspector shows **nothing** for the just-completed turn until the user sends *another*
message and then clicks back on the earlier one. So the data exists in persistence but
the first selection doesn't surface it.

## Likely cause (needs confirmation)

Selecting a bubble calls `viewModel.selectInspectionTurn(_:)` →
`selectedInspectionTurnIndex` changes → `ChatView`'s `.onChange` calls
`inspectionViewModel.select(conversationId:turnIndex:)`, which reads the persisted
`TurnInspectionModel` row for that index. The symptom (correct after a *later* turn)
points at an index/timing mismatch between the bubble's logical turn index and the
persisted row index — the same one-logical-turn vs many-engine-rows tension addressed for
the response/tool-trace write in YAK-2. The just-finished turn's selected index probably
doesn't line up with a persisted row until subsequent turns shift the indices, or the
inspection row for the final turn isn't readable at the moment of first selection.

## Task
- Trace the selection path and identify why the first `select(...)` returns nil/empty for
  a freshly-completed turn. Fix so a single click on a just-finished assistant message
  immediately loads its prompt/sent/journal/response/tools.
- Add a test (extend `InspectableChatIntegrationTests`) covering: complete one turn →
  select it → inspector presentation is non-empty, no second turn required.

## Pointers
- `Sources/Yakamoz/Views/ChatView.swift` (`.onChange(of: viewModel.selectedInspectionTurnIndex)`, `onSelectTurn`)
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`selectInspectionTurn`, `selectedInspectionTurnIndex`, `selectedTurnState`)
- `Sources/YakamozCore/Inspection/InspectionViewModel.swift` (`select`, `presentation`)
- `Sources/YakamozCore/Inspection/SwiftDataTurnInspector.swift` (`inspection`, `latestTurnIndex`)
- Related: [YAK-2](YAK-2-persisted-turn-index-semantics.md)
