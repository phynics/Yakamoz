# YAK-T6 — Truncate long terminal command output + retrievable full-output store

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** product follow-up (2026-06-30)
- **Feature family:** Terminal workspace (spec/plan `docs/superpowers/{specs,plans}/2026-06-26-terminal-workspace*`; continues YAK-T1..T5, complements the YAK-TF series)

## Problem

The terminal tools surface a command's **entire** captured output to the agent verbatim.
`renderRun`/`renderRead` prepend a status tag and then inline the full output:

```swift
// Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:8
func renderRun(_ result: RunResult) -> String {
    switch result {
    case let .finished(output, code):
        return "[exit \(code)]\n\(output)"   // <- full output, no bound
    case let .running(output):
        return "[running]\n\(output)"
    }
}
```

A single `cat bigfile`, build log, or `npm install` floods the model's context with
thousands of lines the agent rarely needs in full — burning tokens and crowding out the
turn. The agent has no way to ask for "just the head", "just the tail", a filtered slice,
or to page through the whole thing on demand.

We want the tool result to **truncate** to a bounded inline slice and end with a notice
telling the agent how to fetch the rest, while the **full** output is retained in a
capped, per-command store the agent can read later via a real tool.

### Relationship to YAK-TF4 (important)

YAK-TF4 deliberately made `TerminalSession`'s live PTY byte buffer **bounded** — it
compacts between commands so finished output does not accumulate. That fix must stand.
This ticket therefore does **not** retain full output in the PTY buffer; it adds a
**separate**, explicitly-capped `commandOutputs` store keyed by command id. The two
mechanisms are orthogonal: the PTY buffer stays compacted; the full-output store is a
distinct LRU-capped map. Call this out in code comments so a future reader does not
"re-fix" one by breaking the other.

## Decisions (from brainstorming, 2026-06-30)

| Question | Decision |
| --- | --- |
| How does the agent fetch full output? | A **real registered tool** `terminal_read_output(command_id, …)`, invoked via native tool-calling. No invented inline call-syntax / no runtime text parsing. |
| Per-command truncation control on `terminal_run`? | `full_output: Bool` (bypass), `show: head\|tail\|both` (which slice is inlined), `grep: String?` (filter output before truncation is considered). |
| Where is full output kept? | Separate **per-command store, LRU-capped** on `TerminalSession`, surviving the YAK-TF4 PTY-buffer compaction. Evicted ids return an `expired` error. |
| Default threshold | 200 lines **or** 16 KB, whichever first. Full output always stored regardless. |
| Default `show` | `both` (head + tail with the middle elided). |

## Approaches Considered

- **Recommended — real tool + separate capped store.** Add `terminal_read_output` as a
  sixth terminal tool; add a `commandOutputs: [UUID: StoredOutput]` LRU map on
  `TerminalSession`; truncate in the render layer and append a notice naming the tool and
  the `command_id`. Robust (no parser), consistent with the existing five-tool pattern,
  and orthogonal to the TF4 PTY buffer.
- **Inline pseudo-syntax** (`(func: "read-command-output", id: "…")` the model emits as
  text, runtime intercepts). Rejected: adds a fragile parser and a parallel non-native
  call path that every provider would have to round-trip cleanly.
- **Unbounded session-lifetime retention.** Rejected: reintroduces exactly the
  unbounded-growth problem YAK-TF4 fixed.

## Agent-facing shape

Truncated `terminal_run` result (head+tail default):

```
[exit 0]
# rg --files src
...
<first N lines>
...
<last M lines>
...
[Output truncated — 1,284 of 9,710 lines (312 KB) shown. Call tool
 `terminal_read_output` with command_id "a1b2c3d4-…" to fetch the full output
 (supports offset/limit paging).]
```

New tool:

| Tool id | Parameters | Returns |
| --- | --- | --- |
| `terminal_read_output` | `command_id: String`, `offset: Int?` (line), `limit: Int?` (lines) | the stored output (or requested page) + total line/byte count, or an `expired`/`unknown id` failure |

Extended `terminal_run` parameters (all optional, additive — existing single-`command`
callers keep working):

| Param | Type | Effect |
| --- | --- | --- |
| `full_output` | Bool (default false) | Bypass truncation; inline the whole output (still stored). |
| `show` | enum `head`/`tail`/`both` (default `both`) | Which slice is inlined when truncated. |
| `grep` | String? | Filter output to matching lines **before** truncation is evaluated. Build the pipeline safely (do not raw-interpolate the pattern into the shell line — pass it as an argument / use a safely-quoted `| grep -- <pattern>` so quoting and injection are not a footgun). |

## Task

- **Render/truncation layer** (`Sources/YakamozCore/Tools/Terminal/TerminalTools.swift`):
  - Replace the unconditional full inline in `renderRun`/`renderRead` with a truncating
    renderer that takes the threshold, `show` mode, the `command_id`, and total
    counts, and appends the standardized truncation notice when (and only when) the
    output exceeds the threshold.
  - Thread `command_id` out of `TerminalSession.run`/`read`/`wait` results so the notice
    and the store agree on the id.
- **`TerminalSession`** (`Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift`):
  - Assign a stable `command_id` (UUID) per executed command (the sentinel uuid already
    exists per command — reuse or map to it).
  - Add `commandOutputs: [UUID: StoredOutput]` with an **LRU cap** (proposed: last 20
    commands **or** 8 MB total, whichever first); evict oldest on insert. Keep this
    **separate** from the TF4-compacted PTY buffer and comment the boundary.
  - Apply `grep` filtering when capturing/finalizing a command's output.
  - Add `readStoredOutput(commandId:offset:limit:)` returning the page or a
    `commandOutputExpired` / `unknownCommandOutput` error.
- **New tool** `TerminalReadOutputTool` in `TerminalTools.swift`: `id =
  "terminal_read_output"`, `requiresPermission = false` (it only reads already-captured
  output of an already-approved command — mirrors `terminal_read`'s no-prompt rationale),
  params schema `command_id` (required) + `offset`/`limit` (optional), routes to
  `session.readStoredOutput(...)`.
- **Extend `TerminalRunTool`** parameter schema + `execute` to parse `full_output`,
  `show`, `grep` and pass them through to `session.run(...)` / the renderer.
- **Wiring:** register `terminal_read_output` everywhere the five terminal tools are
  constructed — `YakamozRuntime.resolveTools(...)` (live path) and
  `TerminalWorkspace.executeTool`/`listTools()` (parity path) — and add its id to
  `ConversationToolSupport` terminal tool options so it toggles with the others.
- **Errors:** add `commandOutputExpired` / `unknownCommandOutput` cases to
  `TerminalWorkspaceError` (`PKError`, stable codes, `userFriendlyMessage`).

## Affected Code

- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:8` — `renderRun` (full inline).
- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:19` — `renderRead` (full inline).
- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:33` — `TerminalRunTool` (param
  schema + `execute`; new optional params).
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift` — `run`/`read`/`wait`
  results carry `command_id`; new capped `commandOutputs` store + `readStoredOutput`;
  `grep` capture; keep separate from the YAK-TF4 buffer compaction.
- `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspace.swift` — `listTools()` /
  `executeTool` route the sixth tool (parity path).
- `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspaceError.swift` — new error cases.
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`resolveTools`) — construct
  `TerminalReadOutputTool` per attached terminal (live path).
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift` — add `terminal_read_output`
  to the terminal tool options gated by `requiresTerminal`.

## Tests (TDD: red → green)

- **Truncation triggers correctly:** output just over threshold truncates and carries a
  notice with the right `command_id` + counts; output just under is inlined whole with no
  notice (boundary on both lines and bytes).
- **`show` modes:** `head` inlines the first slice only; `tail` the last; `both` elides
  the middle — assert which lines appear.
- **`full_output: true`** bypasses truncation even when over threshold (but still stores).
- **`grep`** filters output to matching lines before truncation is evaluated; verify the
  pattern is passed safely (a pattern containing shell metacharacters does not change the
  command run).
- **Store survives TF4 compaction:** run command A (large), then command B; A's full
  output is still fetchable via `terminal_read_output` even though the PTY buffer compacted.
  Add a regression assertion that the PTY retained-byte bound from YAK-TF4 still holds.
- **`terminal_read_output` paging:** `offset`/`limit` return the right slice + totals.
- **LRU eviction:** after exceeding the cap, the oldest id returns `commandOutputExpired`;
  recent ids still resolve. Unknown id returns `unknownCommandOutput`.
- **Wiring:** `terminal_read_output` appears in `resolveTools` only when a terminal is
  attached and survives the `enabledToolIds` filter; `TerminalWorkspace.listTools()`
  includes it.
- Match each file's existing framework (Swift Testing vs XCTest); no `Task.sleep` timing
  assertions — bounded polling per the terminal test strategy.

## Acceptance Criteria

- A command producing large output returns a bounded inline slice plus a clear notice
  naming `terminal_read_output` and the `command_id`; the agent can call that tool to read
  the full output (whole or paged).
- `terminal_run` honors `full_output`, `show`, and `grep`; omitting them preserves today's
  behavior except that over-threshold output is now truncated by default.
- Full output is retained in a **separate, capped** store; the YAK-TF4 PTY-buffer bound is
  unchanged and a regression test proves it.
- Evicted/unknown command ids return a friendly `PKError`, never a crash or empty success.
- `make verify` is green in Yakamoz (trust it over a bare `swift test`).
