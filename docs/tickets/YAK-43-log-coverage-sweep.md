# YAK-43 - Log coverage sweep: instrument silent failure & lifecycle points

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Spec:** `docs/superpowers/specs/2026-06-30-logging-debuggability-design.md`
- **Related:** YAK-40 (provides the `os.Logger` backend + `Log` namespace this depends on), YAK-37 (redaction)

## Problem

Even once logging is bootstrapped (YAK-40), most of Yakamoz still produces **no diagnostic
output** at the points where things actually go wrong: errors are swallowed by `try?` or by
`catch` blocks that recover silently. When a save fails or a tool/workspace operation throws,
there is nothing to see in Console.

This ticket is the *coverage* follow-up to YAK-40's *infrastructure*: walk the swallow sites and
add appropriately-leveled, metadata-tagged logging. It depends on YAK-40 (the `Log.*` namespace
and bootstrap must exist first).

## Affected code (representative — sweep, not exhaustive)

Silent `try?` discards of fallible side effects:
- `Sources/Yakamoz/Views/ChatView.swift:293,413` — `try? modelContext.save()`
- `Sources/Yakamoz/Views/TypedReplyControls.swift:33` — `try? modelContext.save()`
- `Sources/Yakamoz/Views/PersonaEditorView.swift:141` — `try? modelContext.save()`
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift:128,232,241,273` — `try? modelContext.save()`
  and `:151,222,225,265` — `try? modelContext.fetch(...) ?? []` (silently treats failure as empty)
- `Sources/YakamozCore/Persistence/AgentStores.swift:204` — `try? fetch` → `false`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift:226` — `(try? await loadTranscript(...)) ?? .empty`
  (a failed transcript load silently becomes an empty conversation)

`catch` blocks that recover/return without logging:
- `Sources/YakamozCore/Persistence/{MessageStore,TimelineStore,AgentStores,ToolAndOriginStores}.swift`
  (~25 catch sites) — persistence failures are the highest-value thing to see.
- `Sources/YakamozCore/Workspaces/FileSystemWorkspace.swift:52,65,83,95`
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift:43`
- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:77,232,239,241`
- `Sources/Yakamoz/Views/ConversationListView.swift:93`, `SettingsView.swift:105`

Out of scope (intentional, leave as-is): `try? await Task.sleep(...)` poll/backoff sites in
`TerminalSession.swift` — cancellation there is expected, not an error.

## Approach

- Persistence save/fetch failures → `Log.runtime`/store-specific logger at `.error` (saves) or
  `.warning` (fetch-fallbacks), with metadata identifying the entity (`store`, `conversationID`,
  `timelineId`, count). Do not change control flow — keep the existing recovery; just make it visible.
- Workspace/terminal/tool catch sites → `.warning`/`.error` with `workspaceID`/`toolName` metadata.
- View-layer `try? save()` → log at `.error`; consider whether a user-visible failure is warranted
  (note in ticket, don't necessarily add UI here).
- A silently-empty fallback that masks a real failure (e.g. `loadTranscript` → `.empty`,
  `fetch ?? []`) must log at `.warning` so "why is this conversation empty/missing?" is answerable.
- Pick levels deliberately: `.debug` for routine flow, `.info`/`.notice` for lifecycle milestones,
  `.warning` for recovered-but-suspicious, `.error` for genuine failures.

## YAK-37 invariant

Log identifiers, counts, and `ErrorKit.userFriendlyMessage(for:)` — never raw note/message
content, prompt text, tool arguments, file contents, or secrets.

## Tests

- Persistence-store failure paths emit a log record (inject a failing `ModelContext` / store seam)
  at the expected level with the expected metadata key(s).
- `loadTranscript` failure path logs a `.warning` before returning `.empty`.
- No regression: control flow / return values at instrumented sites are unchanged.
- Match each file's existing test framework; don't mix within a file.

## Acceptance criteria

- Previously-silent `try?` and recover-without-log `catch` sites in the listed files emit
  appropriately-leveled, metadata-tagged logs through the YAK-40 `Log.*` loggers.
- Intentional cancellation sleeps remain unlogged.
- Levels are used deliberately (not everything at `.error`).
- Logging is redaction-safe (YAK-37); control flow is unchanged.
- Yakamoz `make verify` is green.
