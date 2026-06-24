# YAK-4 — Land facade store-consistency refactor (Monad double memory store)

- **Status:** Done
- **Priority:** Medium
- **Repos:** PositronicKit + Monad
- **Surfaced by:** noticed while wiring Yakamoz's facade composition (CP5)

Implemented in-tree and verified with `swift build && swift test` in both `PositronicKit` and `Monad` on 2026-06-24.

## Problem

A pre-existing, unrelated-to-Yakamoz design plan is sitting **untracked** in the
PositronicKit checkout:

```
../PositronicKit/docs/superpowers/plans/2026-06-22-facade-store-consistency.md
```

It documents a real bug: the `PositronicKit` facade lets a caller pass a
`persistence:` store set **and** a separately-built `TimelineManager`/`ToolRouter`
that may wrap *different* store instances. `TimelineManager` snapshots its stores at
construction, so the two can silently diverge. Concretely (per the plan),
`Monad/Sources/MonadServer/MonadServerFactory.swift` builds `TimelineManager.Stores`
without `memoryStore`, so it defaults to an in-memory store while the facade's
`persistence:` block gets the real GRDB-backed memory store — **two live memory
stores in one server.**

## Task

1. Decide the home for that plan file (commit it into PositronicKit, or move it to
   wherever PositronicKit tracks plans) — it is currently untracked and at risk of
   being lost.
2. Execute it: remove the `timelineManager:`/`toolRouter:` override params from the
   facade initializers, add the non-store knobs (`workspaceCreator`,
   `sectionProviders`, `runtimeToolPolicy`) to `RuntimeConfiguration`, have the facade
   always derive `TimelineManager`/`ToolRouter` from one `PersistenceConfiguration`,
   and migrate all call sites (PositronicKit, `PKTestSupport.TestRuntime`, examples,
   tests, `Monad/.../MonadServerFactory.swift`).
3. `swift build && swift test` green in PositronicKit and Monad.

> Note: Yakamoz uses the flat per-store facade initializer and does **not** pass
> `timelineManager:`/`toolRouter:`, so it needs no code change — only a build check
> after the refactor.

## Pointers
- `../PositronicKit/docs/superpowers/plans/2026-06-22-facade-store-consistency.md` (the plan)
- `../PositronicKit/Sources/PositronicKit/PositronicKit.swift`
- `../Monad/Sources/MonadServer/MonadServerFactory.swift`
