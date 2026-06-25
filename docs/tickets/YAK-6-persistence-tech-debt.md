# YAK-6 — Persistence tech-debt cleanup

- **Status:** Done
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** CP4 / CP7 (persistence adapters + shell)

> **Resolved** in commit `23c0858`: `toolCallsData` renamed to
> `messageEnvelopeData` (`PersistenceModels.swift`, `MessageStore.swift`), and the
> `ConversationModel` (UI shell) vs `TimelineModel` (PositronicKit surface)
> ownership boundary documented in `PersistenceModels.swift`. Field-derivation
> sync (part 2's stretch) intentionally left as future work.

Two small, non-blocking cleanups in the SwiftData layer. Both are documented in
code today; this ticket tracks paying them down.

## 1. `MessageModel.toolCallsData` is a misnomer

`SwiftDataMessageStore` stores the **entire** `ConversationMessage` (recalledMemories,
parentId, think, toolCalls, toolCallId, agentInstanceId, snapshotData, …) as a JSON
envelope in a field named `toolCallsData` — a leftover name from when it only held
tool calls. Scalar columns (id, role, content, createdAt, …) are the authoritative
queryable copy; the blob carries the rest.

**Fix:** rename the field to something honest (e.g. `messageEnvelopeData`) and update
`MessageModel` + `MessageStore.swift`. Safe to rename (fresh app, no shipped store);
do it as a clean migration-free change while there's no production data.

- `Sources/YakamozCore/Models/PersistenceModels.swift` (`MessageModel`)
- `Sources/YakamozCore/Persistence/MessageStore.swift`

## 2. `ConversationModel` vs `TimelineModel` duality

Yakamoz has two overlapping model families: UI shell (`ConversationModel`,
`WorkspaceModel`) and PositronicKit-protocol surface (`TimelineModel`,
`WorkspaceReferenceModel`). They're intentionally distinct and a conversation pairs
a `ConversationModel` + a `Timeline` on one shared `UUID` (see
`ConversationCoordinator`), but the two id spaces + partial field overlap are a
maintenance hazard.

**Task:** document the ownership boundary explicitly (which model is the source of
truth for title, createdAt, archival, etc.), and consider whether
`ConversationModel` should derive/sync a few fields from the timeline instead of
duplicating them. Low urgency; revisit if the two ever disagree.

- `Sources/YakamozCore/Models/PersistenceModels.swift`
- `Sources/YakamozCore/Runtime/ConversationCoordinator.swift`
