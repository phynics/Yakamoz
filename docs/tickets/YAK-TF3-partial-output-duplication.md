# YAK-TF3 — Partial output duplicated across `terminal_run` → `terminal_read`/`terminal_wait`

**Severity:** 🟠 Medium (incorrect output contract)
**Area:** Terminal workspace — output bookkeeping
**Source:** Integration review of merge `78a7b7f`

## Problem

The two exit branches of `collectUntilMark` treat `readCursor` asymmetrically.
The `.finished` branch advances it; the `.running` branch does not.

```swift
// Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:310
private func collectUntilMark(mark: String, graceMs: Int) async -> RunResult {
    let deadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)
    while true {
        if let found = extractFinished(mark: mark) {
            pendingMark = nil
            lastExitCode = found.exitCode
            pendingStart = buffer.count
            readCursor = buffer.count          // ← finished advances the cursor
            return .finished(found.output, found.exitCode)
        }
        if hasExited || Date() >= deadline {
            return .running(partialOutputSinceBegin(mark: mark))  // ← running does NOT
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
    }
}
```

`run` set `readCursor = buffer.count` *before* sending `BEGIN`
(`TerminalSession.swift:180`). When the grace period expires, `run` returns
`.running(output)` containing everything from `BEGIN` to now, but leaves
`readCursor` pointing before `BEGIN`. The next `read()`/`wait()` computes its
slice via `sinceReadCursor`, which clamps the lower bound up to the `BEGIN`
marker — so it **re-emits the exact bytes `run` already returned**, then appends
any new output. This violates the documented contract ("output accumulated since
the last `read`/`wait`/`run` call") and makes an agent polling a long-running
command see its early output twice.

## Affected code

- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift:322` (`.running` branch)

## Fix

Advance the read cursor to the current buffer end before returning `.running`,
mirroring the `.finished` branch.

### before

```swift
if hasExited || Date() >= deadline {
    return .running(partialOutputSinceBegin(mark: mark))
}
```

### after

```swift
if hasExited || Date() >= deadline {
    let partial = partialOutputSinceBegin(mark: mark)
    readCursor = buffer.count   // already-returned output is not re-emitted by read()/wait()
    return .running(partial)
}
```

## Tests (add)

- `run("sleep 1; echo A; sleep 5", graceMs: small)` returns `.running` containing
  `A`; the immediately following `read()` returns output **not** containing `A`
  again (only output produced after the grace cutoff).
- A `wait()` after a `.running` run does not double-count the pre-cutoff output.

## Acceptance criteria

- For any command, the concatenation of `run`'s `.running` output plus all
  subsequent `read`/`wait` outputs equals the command's full output with **no
  duplicated regions**.
