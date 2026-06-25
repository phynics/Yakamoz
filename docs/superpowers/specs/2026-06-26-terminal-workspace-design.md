# Terminal Workspace — Design Spec

**Date:** 2026-06-26
**App:** Yakamoz (non-sandboxed local macOS showcase app)
**Status:** Approved design, pending implementation plan
**Scope note:** Yakamoz-only for now. The abstractions are designed so they *could* later
move to `PositronicKit`, but this spec does not target that — there is no server/client model
here, all workspaces are local.

## 1. Summary

Add a **terminal workspace**: a long-lived, PTY-backed interactive shell that an agent can
drive through tools. It is a first-class workspace (its own `WorkspaceProtocol` instance),
offered in the workspaces UI, and created/attached from an existing folder workspace (its
initial working directory is that folder's root). The human does **not** get an interactive
terminal pane — the terminal is agent-driven, and the human observes each command as a tool
trace in the existing Tools inspector tab. Every command the agent runs is gated behind a
**per-command user permission prompt**.

### Decisions locked during brainstorming

| Question | Decision |
| --- | --- |
| Where does the shell run? | Locally, in-process. No server/client. |
| Fidelity | **Line-oriented persistent shell** — not full terminal emulation. No need to render `vim`/`top`. |
| PTY backbone | **PTY-backed** (real pseudo-terminal so cwd/env/job-control/background jobs work and programs see a tty). |
| Backend technology | **Import SwiftTerm**, use its `LocalProcess` PTY layer only. Avoids the unsafe `forkpty`-from-Swift trap; ignore the emulator/views. |
| Agent tool surface | `terminal_run` (non-blocking) + interaction escape hatch (`terminal_read` / `terminal_send_input` / `terminal_interrupt` / `terminal_wait`). Agent regains control to re-check status. |
| Human UI | **Agent-only, no terminal pane.** Human sees command/output via the Tools inspector tab. |
| Attach model | **Separate workspace, multi-attach.** `ConversationModel` goes from a single `workspaceId` to a list of attached workspace ids. |
| Lifecycle | Sessions **persist across timeline switches** (kept alive in a registry), die on detach / app quit. **No relaunch survival** — attachment persists, live process state does not. |
| Safety | The shell is **not jailed** (a real shell can `cd /`). Accepted as an inherent, documented tradeoff, mitigated by the per-command permission prompt. |

## 2. Why these choices

- **SwiftTerm `LocalProcess`** removes the one genuinely dangerous part of this feature — PTY
  setup. `forkpty` is not safe to call from Swift (fork-without-exec; the Swift runtime is not
  async-signal-safe in that window). `LocalProcess` spawns a process on a PTY safely and exposes
  `send(data:)` plus a delegate `dataReceived(slice:)`. We use only that slice; the VT100
  emulator and the AppKit/UIKit views are not used. SwiftTerm stays a `YakamozCore` dependency
  and never reaches the `Yakamoz` app target (preserving the README's app-target boundary).
- **Line-oriented, `TERM=dumb`** keeps us out of the terminal-emulation business. We treat shell
  output as a byte stream and strip any stray ANSI on capture, rather than maintaining a screen
  buffer.
- **Non-blocking `terminal_run`** matches the request that the agent "gets focus back" to check
  status and interact — long-running and interactive commands don't wedge the turn.
- **Multi-attach** matches the "offered as an available workspace" framing and mirrors
  `TimelineModel.attachedWorkspaceIds` (which is already plural); `ConversationModel` is the lone
  single-id holdout.

## 3. Current-state references (read before implementing)

| Concern | Location |
| --- | --- |
| Workspace contract | `../PositronicKit/Sources/PositronicKit/Models/Workspace/WorkspaceProtocol.swift` |
| Existing local workspace | `Sources/YakamozCore/Workspaces/FileSystemWorkspace.swift` |
| Workspace factory (`WorkspaceCreating`) | `Sources/YakamozCore/Workspaces/FileSystemWorkspaceFactory.swift` |
| Conversation / workspace models | `Sources/YakamozCore/Models/PersistenceModels.swift` (`ConversationModel` ~L42, `WorkspaceModel` ~L182) |
| Tool gating + attach/detach | `Sources/YakamozCore/Tools/ConversationToolSupport.swift` |
| **Live** tool composition (source of truth for agent tools) | `Sources/YakamozCore/Runtime/YakamozRuntime.swift` → `resolveTools(enabledToolIds:workspaceRoot:)` ~L110 |
| Composition root | `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`init` ~L76) |
| Attach UI | `Sources/Yakamoz/Views/WorkspacePicker.swift` |
| XcodeGen package/deps | `project.yml` (`packages:` ~L18, `YakamozCore` `dependencies:` ~L55) |

### Critical implementation note — the dual tool path

The **live agent tools come from `YakamozRuntime.resolveTools(...)`**, which builds `AnyTool`
values directly and passes them to `ChatViewModel.tools`. `FileSystemWorkspace.executeTool` and
`FileSystemWorkspaceFactory` are a **parallel** identity/inspection path, not the live chat
path. The terminal feature must follow the same dual pattern the filesystem tools use:

1. Define the terminal tools once as `Tool` types (e.g. `TerminalRunTool`).
2. Construct them in `resolveTools(...)` for the live path (this is what the agent actually calls).
3. Route them from `TerminalWorkspace.executeTool` for parity/inspection.

Both must be backed by the **same** `TerminalSession` instance obtained from the registry, so a
command run via the live path and a status read via either path see one shell.

## 4. Architecture

```
TerminalSession (actor)            wraps SwiftTerm LocalProcess; owns the PTY, an output
                                   ring-buffer, and sentinel-based command-boundary tracking.
        ▲ obtained by id
TerminalSessionRegistry (actor)    workspaceId -> TerminalSession. Lazy-spawns on first use,
                                   keeps sessions alive across timeline switches, tears down
                                   on detach / app termination. Held by YakamozRuntime.
        ▲
TerminalWorkspace (WorkspaceProtocol)  identity/health/listTools + executeTool routing (parity
                                   path). resolveTools(...) builds the live AnyTools from the
                                   same session.
        ▲
Tools: terminal_run / terminal_read / terminal_send_input / terminal_interrupt / terminal_wait
        │ each terminal_run is gated by:
TerminalCommandApproving (protocol)    async user-permission gate; default-deny if unwired.
```

### 4.1 `TerminalSession` (actor) — the crux

Owns one `SwiftTerm.LocalProcess`. Spawns a login shell (`/bin/zsh`) on a PTY with
`cwd = folder root` and environment including `TERM=dumb`. Buffers all received bytes into an
append-only buffer with a read cursor per logical command.

**Command-boundary mechanism (sentinel).** To run `CMD`, the session writes:

```
CMD; printf '\n<MARK-{uuid}>:%s\n' "$?"\n
```

It then reads incoming bytes until the line `<MARK-{uuid}>:<n>` appears; `<n>` is the exit
code. Everything between the echoed input and the marker is the command output (the echoed
command line and the marker line are stripped; stray ANSI is stripped). A fresh random
`{uuid}` per command prevents a command that prints a literal marker from spoofing completion.

**Non-blocking semantics.** `TerminalSession` exposes:

- `run(_ command:) async -> RunResult` — writes the sentinel-wrapped command, waits up to a
  bounded grace period (default ~2s). Returns `.finished(output, exitCode)` if the marker
  arrived, else `.running(outputSoFar)` and leaves the command executing.
- `read() async -> ReadResult` — returns bytes accumulated since the last read plus status
  (`running` / `finished(exitCode)`).
- `sendInput(_ text:) async` — raw `send(data:)` to the shell (answers an interactive prompt;
  caller includes a newline when needed).
- `interrupt() async` — sends `0x03` (Ctrl-C).
- `wait(timeoutMs:) async -> ReadResult` — suspends until the marker arrives or the timeout
  elapses.

Only one foreground command is tracked at a time; `run` while a command is still running
returns an error result (the agent should `read`/`wait`/`interrupt` first).

### 4.2 `TerminalSessionRegistry` (actor)

`map[workspaceId: TerminalSession]`. `session(for:rootURL:)` returns the existing session or
lazily spawns one. `terminate(workspaceId:)` kills the shell and removes the entry.
`terminateAll()` is called on app shutdown. Held by `YakamozRuntime` so the same session
survives the user switching between timelines.

### 4.3 `TerminalWorkspace` (`WorkspaceProtocol`)

Mirrors `FileSystemWorkspace`'s shape: `id`, `reference` (uri via a new
`WorkspaceURI.terminal(...)` helper or reuse of `requestOriginShell`, `location: .attached`,
`rootPath` = folder root, `trustLevel: .full`), `listTools()` returning the five terminal tool
ids, and `executeTool(id:parameters:)` routing to the tool types (parity path). File operations
(`readFile`/`writeFile`/`listFiles`/`deleteFile`) throw `WorkspaceError.toolExecutionNotSupported`
— this workspace is a shell, not a file store.

### 4.4 The five tools

Defined as `Tool` types in `Sources/YakamozCore/Tools/Terminal/`. Each holds a reference to its
`TerminalSession` (resolved via the registry) and `terminal_run` additionally holds the
`TerminalCommandApproving` gate.

| Tool id | Parameters | Returns |
| --- | --- | --- |
| `terminal_run` | `command: String` | output, exit code (if finished), `status` |
| `terminal_read` | — | new output since last read, `status` |
| `terminal_send_input` | `text: String` | acknowledgement |
| `terminal_interrupt` | — | acknowledgement |
| `terminal_wait` | `timeout_ms: Int?` | output, `status` |

### 4.5 `TerminalCommandApproving` — the permission gate

```swift
public enum TerminalApprovalDecision: Sendable { case approve, deny, allowForSession }

public protocol TerminalCommandApproving: Sendable {
    func requestApproval(command: String, workspaceId: UUID) async -> TerminalApprovalDecision
}
```

- `terminal_run` calls `requestApproval(command:workspaceId:)` **before** touching the shell.
  The call suspends (continuation) until the user acts.
- **`deny`** → the tool returns a failure `ToolResult` the agent sees ("command denied by
  user"); the shell is never written to.
- **`allowForSession`** → the registry records that this terminal is pre-approved for the rest
  of the app run; subsequent `terminal_run`s on that terminal skip the prompt.
- **Default-deny**: if no approver is injected, every `terminal_run` is denied. The backend is
  therefore never an un-gated arbitrary-exec primitive, even when misconfigured.

**Scope:** Only `terminal_run` prompts. `terminal_send_input` / `terminal_interrupt` against an
already-running, already-approved command do **not** re-prompt — they steer a command the user
already approved, and prompting for a Ctrl-C would be perverse.

The concrete approver lives in the app/runtime layer and bridges to a SwiftUI banner in
`ChatView` showing the exact command with **Approve / Deny / Allow for this terminal**. The
agent is visibly blocked while the prompt is pending.

## 5. Persistence & multi-attach changes

### 5.1 `ConversationModel`: single id → list

```swift
// BEFORE (PersistenceModels.swift ~L46)
public var workspaceId: UUID?

// AFTER
public var attachedWorkspaceIds: [UUID]   // empty == none
```

SwiftData migration: a stage that maps an existing non-nil `workspaceId` to a one-element
`attachedWorkspaceIds`. (If a lightweight migration cannot transform a renamed property, retain
`workspaceId` as deprecated/private and fold it into the array on read; the plan ticket decides
the exact mechanism after checking the current schema-version setup.)

### 5.2 `WorkspaceModel`: add a `kind` discriminator

```swift
public enum WorkspaceKind: String, Codable, Sendable { case folder, terminal }

// added field (default .folder so existing rows decode unchanged)
public var kind: WorkspaceKind = .folder
```

A terminal `WorkspaceModel` stores the originating folder path as its `folderPath` (used as the
shell's initial cwd) and a `displayName` like "Terminal — <folder>". No parallel `@Model`.

### 5.3 `ConversationToolSupport`

- Add terminal tool options (the five ids) to `toolOptions(...)`, available when a terminal
  workspace is attached (gate parallel to the existing `requiresWorkspace` file-tool gate; a new
  `requiresTerminal` flag or equivalent).
- `WorkspaceAttachmentSupport` gains `attachTerminal(to:fromFolder:)` /
  `detachWorkspace(id:)` operating on the `attachedWorkspaceIds` list, enabling/disabling the
  terminal tool ids the same way folder attach toggles the file tool ids.

### 5.4 `YakamozRuntime.resolveTools`

```swift
// signature extends to carry attached terminal context
public nonisolated func resolveTools(
    enabledToolIds: [String],
    workspaceRoot: URL?,
    terminals: [TerminalToolContext]   // (workspaceId, rootURL) per attached terminal
) -> [AnyTool]
```

For each attached terminal, append the five terminal `AnyTool`s, each capturing the session
(via `registry.session(for:rootURL:)`) and, for `terminal_run`, the approver. Then filter by
`enabledToolIds` exactly as today.

## 6. Error handling

`TerminalWorkspaceError: PKError` with stable codes and `userFriendlyMessage`:
`sessionSpawnFailed`, `shellExited`, `commandAlreadyRunning`, `notRunning`. Surface nested
errors via `ErrorKit.userFriendlyMessage(for:)`. A **timeout is a status, not an error** —
`terminal_run`/`terminal_wait` return a `running` status, never throw, on grace-period expiry.

## 7. Testing strategy

Real shell on the macOS test host; **no network**; **no `Task.sleep`-based timing assertions** —
use bounded polling against `read()`/`wait()`. Match each file's existing framework (Swift
Testing for newer files, XCTest where present).

- **`TerminalSession`**: `echo hello` → output + exit 0; non-zero exit code propagation
  (`false`); persistent cwd (`cd /tmp` then `pwd`); non-blocking long command
  (`sleep 1; echo done`) → `run` returns `running`, then `wait`/`read` reaches `finished`;
  `interrupt()` on `sleep 100` returns control with a non-zero/interrupted status;
  `sendInput` answering a `read x; echo $x`; ANSI stripping; marker-spoof resistance (a command
  that prints a fake marker does not prematurely "finish").
- **`TerminalSessionRegistry`**: same session id returned across a simulated timeline switch;
  `terminate` kills and a subsequent request spawns a fresh shell.
- **Permission gate**: `deny` → shell untouched, agent-visible failure; default-deny when no
  approver; `allowForSession` suppresses subsequent prompts for that terminal only.
- **Model/migration**: `workspaceId` → `attachedWorkspaceIds` migration; `kind` defaults
  `.folder` for existing rows; attach/detach multiple workspaces; `enabledToolIds` toggles.
- **`resolveTools`**: terminal tools appear only when a terminal is attached and survive the
  `enabledToolIds` filter.

## 8. Safety posture (documented tradeoff)

The terminal shell is a **real shell and is not confined** to the folder root — it can `cd`
anywhere the user can. This is inherent to offering a usable shell and is accepted deliberately,
consistent with Yakamoz being a non-sandboxed, single-user local dev/showcase app at
`trustLevel .full`. It is mitigated by the **per-command permission prompt** (default-deny,
explicit per-command approval, opt-in per-terminal "allow for session"). This tradeoff will be
documented in the README alongside the existing non-sandbox and plaintext-secrets notes. Do not
copy this pattern into anything requiring real isolation.

## 9. Ticket decomposition

1. **YAK-T1 — Multi-workspace attachment.** `ConversationModel` single→list + migration;
   `WorkspaceAttachmentSupport`/`WorkspacePicker` manage a list; picker shows all attached
   workspaces. Foundation; no terminal yet.
2. **YAK-T2 — Timeline/workspace state-consistency hardening.** Guarantee that
   conversation↔workspace attachment, `enabledToolIds`, and session/registry references stay
   consistent across detach, conversation delete, app relaunch, and orphaned-workspace cleanup.
   Invariant tests. (Lands before the terminal introduces live session state.)
3. **YAK-T3 — Terminal backend.** Add SwiftTerm dependency; `TerminalSession` +
   `TerminalSessionRegistry`; sentinel command-boundary + non-blocking semantics. Pure core +
   tests. No agent wiring, no UI.
4. **YAK-T4 — TerminalWorkspace + agent tools + approval seam.** `WorkspaceProtocol` impl; the
   five tool types; `TerminalCommandApproving` (default-deny) gate; `ConversationToolSupport`
   options + persistence `kind`; `resolveTools` wiring.
5. **YAK-T5 — Workspaces-tab UI + approval prompt.** Available-workspaces affordance; folder
   workspace's "Create & attach Terminal" action; `ChatView` approval banner wiring a concrete
   `TerminalCommandApproving`.

## 10. Out of scope (YAGNI)

- Interactive terminal pane for the human; full VT100 emulation; rendering TUI apps.
- Relaunch survival of live shell state; detached/daemonized sessions.
- Shell confinement/jailing; sandboxing.
- Moving any of this into `PositronicKit` (possible later, not now).
- Multiple concurrent foreground commands per session.
