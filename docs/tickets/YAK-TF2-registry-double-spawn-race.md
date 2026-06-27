# YAK-TF2 — Registry `session(for:)` double-spawns shells under concurrent first use

**Severity:** 🟠 Medium (resource leak + state divergence)
**Area:** Terminal workspace — session lifecycle
**Source:** Integration review of merge `78a7b7f`

## Problem

`TerminalSessionRegistry.session(for:rootURL:)` does a check-then-act across an
`await`, so two concurrent first-use callers each spawn a shell.

```swift
// Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift:27
public func session(for id: UUID, rootURL: URL) async throws -> TerminalSession {
    if let existing = sessions[id] { return existing }
    let session = try await TerminalSession(rootURL: rootURL)  // ← actor suspends here
    sessions[id] = session
    return session
}
```

The actor suspends at `await TerminalSession(...)` (its `init` is async and runs
`prepareShell`). During that window a second call to `session(for: sameId)` runs,
sees `sessions[id] == nil`, and spawns a **second** `TerminalSession`. The later
store wins; the other shell process is **leaked** — it is not in `sessions`, so
neither `terminate(id:)` nor `terminateAll()` can ever kill it. Worse, the two
callers receive *different* shell instances, so e.g. `terminal_run` lands on
shell A while a concurrent `terminal_read` reads shell B and sees nothing.

### Trigger

The LLM emits parallel tool calls in a single turn (e.g. `terminal_run` +
`terminal_read`) on a terminal whose session hasn't been spawned yet. `ChatEngine`
may execute tool calls concurrently; all five tools share the one registry.

## Affected code

- `Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift:27`

## Fix

Deduplicate concurrent spawns by storing an in-flight `Task` keyed by id, so all
callers await the same spawn. Cache the resulting session; drop the task entry on
failure.

### before

```swift
public actor TerminalSessionRegistry {
    private var sessions: [UUID: TerminalSession] = [:]
    private var sessionAllow: Set<UUID> = []

    public func session(for id: UUID, rootURL: URL) async throws -> TerminalSession {
        if let existing = sessions[id] { return existing }
        let session = try await TerminalSession(rootURL: rootURL)
        sessions[id] = session
        return session
    }
```

### after

```swift
public actor TerminalSessionRegistry {
    private var sessions: [UUID: TerminalSession] = [:]
    private var spawning: [UUID: Task<TerminalSession, Error>] = [:]
    private var sessionAllow: Set<UUID> = []

    public func session(for id: UUID, rootURL: URL) async throws -> TerminalSession {
        if let existing = sessions[id] { return existing }
        if let inFlight = spawning[id] { return try await inFlight.value }

        let task = Task { try await TerminalSession(rootURL: rootURL) }
        spawning[id] = task
        defer { spawning[id] = nil }
        do {
            let session = try await task.value
            sessions[id] = session
            return session
        } catch {
            throw error
        }
    }
```

> `terminate(id:)`/`terminateAll()` should also cancel any in-flight `spawning`
> entry for that id and clear the map, so a session spawned concurrently with a
> teardown is still reaped.

## Tests (add)

- Fire N concurrent `session(for: sameId)` calls; assert they all return the
  **same** `TerminalSession` instance (identity) and that exactly one shell PID
  was created.
- After `terminate(id:)`, a fresh `session(for:)` spawns a new shell (existing
  behavior, keep it green).

## Acceptance criteria

- Concurrent first-use of a terminal yields exactly one shell, shared by all
  callers; no leaked PTY processes.
