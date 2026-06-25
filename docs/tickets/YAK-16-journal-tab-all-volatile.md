# YAK-16 — [BUG] Journal tab marks everything volatile / shows no updates

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz (+ likely PositronicKit seam)
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The Journal inspector tab categorizes every section as "volatile" and reports no
changed/added/removed updates and a zero stable prefix — so it conveys nothing useful
across turns.

## Likely cause (needs confirmation)

`JournalInspectorView` renders from a `TurnJournalSnapshot` (`stablePrefixCount`,
`changedSemiStableIDs`, `addedSemiStableIDs`, `removedSemiStableIDs`). If those arrive as
`0`/empty, every section falls into the volatile bucket. Recall the design constraint
(spec §): the **public** `PromptJournalDiff` exposes only the overlay ID sets —
`stablePrefixCount`/`didCompact` are internal to PositronicKit, and `TurnJournalSnapshot`
has been constructed with `stablePrefixCount: 0, didCompact: false` hardcoded in places.
So the snapshot persisted via the `TurnInspecting` seam may never carry the engine's real
stable-prefix/diff data — the inspector is faithfully showing empty data.

## Task
- Determine whether the `TurnInspecting`/`TimelinePromptHistory.publicJournalDiff` seam
  actually carries real stable-prefix + diff data per turn, or whether it's zero-filled.
- If the data isn't exposed, extend the PositronicKit seam to surface real
  `stablePrefixCount` + changed/added/removed IDs (mirroring how `TurnInspecting` was
  added), thread it into `TurnJournalSnapshot`, and persist it.
- Make the Journal tab show a non-trivial stable prefix and real per-turn deltas across a
  multi-turn conversation.
- Add a test asserting a second turn reports a non-zero stable prefix and/or non-empty
  diff against the first.

## Pointers
- `Sources/Yakamoz/Views/Inspector/JournalInspectorView.swift` (`volatileSections`, the stat/idList rows)
- `Sources/YakamozCore/Inspection/InspectionDTOs.swift` (`JournalDTO`), `SwiftDataTurnInspector`
- `../PositronicKit/Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift` (`publicJournalDiff`)
- `../PositronicKit/.../Protocols/TurnInspecting.swift` (`TurnJournalSnapshot`, `PromptJournalDiff`)
