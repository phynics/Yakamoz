# YAK-TF4 — Unbounded `TerminalSession.buffer` growth (design says ring-buffer)

**Severity:** 🟡 Medium/Low (memory growth on long-lived sessions)
**Area:** Terminal workspace — output storage
**Source:** Integration review of merge `78a7b7f`

## Problem

`TerminalSession.buffer` is an append-only `[UInt8]` that is never trimmed after
startup. The only `removeAll` is the one-shot drain in `prepareShell`.

```swift
// Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:88
private var buffer: [UInt8] = []
...
// Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:297
func appendOutput(_ bytes: ArraySlice<UInt8>) {
    buffer.append(contentsOf: bytes)   // grows forever
}
```

Sessions are intentionally long-lived (kept alive across timeline switches by the
registry), so every byte of every command's output — build logs, `cat bigfile`,
etc. — is retained for the session's whole lifetime. Memory grows without bound.

This contradicts the architecture doc (§4: *"owns the PTY, an output ring-buffer,
and sentinel-based command-boundary tracking"*) — the implementation is not a ring
buffer.

## Affected code

- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:88` (`buffer`)
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:297` (`appendOutput`)
- All offset users: `pendingStart`, `readCursor`, `extractFinished`,
  `beginMarkerEnd`, `sinceReadCursor`, `partialOutputSinceBegin`.

## Fix (two viable approaches)

### Option A — compact after each completed command (simplest, recommended)

After a command resolves (in the `.finished` branch of `collectUntilMark` and in
`read()`'s finished path), drop everything the cursors have moved past. Since all
buffer positions (`pendingStart`, `readCursor`) are absolute offsets, introduce a
`bufferBase` offset and translate, **or** simpler: when no command is pending and
`readCursor == buffer.count`, reset:

```swift
// when a command has fully finished AND all output surfaced:
if pendingMark == nil, readCursor == buffer.count {
    buffer.removeAll(keepingCapacity: true)
    pendingStart = 0
    readCursor = 0
}
```

Drop this into the finished paths after the cursors are advanced. This bounds the
buffer to a single command's output. **Verify** it composes with the
between-commands `read()` (no pending) path, which also expects to surface trailing
output before reset.

### Option B — true ring buffer with a `bufferBase`

Track `bufferBase: Int` = absolute offset of `buffer[0]`; rewrite every absolute
index (`pendingStart`, `readCursor`, marker ranges) as `absolute - bufferBase`;
trim the front past `min(pendingStart, readCursor)` and bump `bufferBase`. More
invasive; only do this if Option A's "reset between commands" is insufficient
(e.g. need bounded memory *within* one huge streaming command).

## Tests (add)

- After running many small commands in a loop on one session, `buffer.count` (or a
  test-only accessor) stays bounded rather than growing linearly with command
  count.
- Output correctness of a normal `echo`/exit-code command is unchanged after the
  compaction (regression guard).

## Acceptance criteria

- A long-lived session that has produced large cumulative output does not retain
  it all; steady-state memory is bounded by roughly the in-flight command's output.
