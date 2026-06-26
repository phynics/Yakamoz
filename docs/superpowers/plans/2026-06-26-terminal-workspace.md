# Terminal Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an agent-driven, PTY-backed terminal workspace to Yakamoz — a persistent line-oriented shell the agent runs commands in (with a per-command user permission prompt), offered as a first-class attachable workspace.

**Architecture:** A `TerminalSession` actor wraps SwiftTerm's `LocalProcess` (the only safe way to spawn a PTY from Swift) and tracks command boundaries with a per-command random sentinel. A `TerminalSessionRegistry` actor keyed by workspace id keeps sessions alive across timeline switches. Five tools (`terminal_run` + interaction escape hatch) drive the session; `terminal_run` is gated by a default-deny `TerminalCommandApproving` protocol bridged to a SwiftUI banner. `ConversationModel` moves from a single `workspaceId` to a list of attached workspace ids (additive SwiftData migration).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, PositronicKit, SwiftTerm (new dependency), XcodeGen, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-26-terminal-workspace-design.md`

**Conventions:**
- Build: `make build`. Test a suite: `make test TEST_FILTER=<SuiteOrClassName>`. Full gate: `make verify`.
- New test files use **Swift Testing** (`@Suite`, `@Test`, `#expect`). Match an existing file's framework when editing it.
- No network in tests; **no `Task.sleep`-based timing assertions** — poll `read()`/`wait()` with bounded budgets.
- Commit after each green step. Keep the `Yakamoz` app target free of any direct `PositronicKit`/`SwiftTerm` symbol — all such code lives in `YakamozCore`.

---

## File Structure

**Created:**
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift` — actor wrapping `LocalProcess`; PTY I/O, output buffer, sentinel command boundaries, non-blocking run/read/send/interrupt/wait.
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift` — actor: workspaceId → session, lazy spawn, lifecycle, session-allow flag.
- `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspace.swift` — `WorkspaceProtocol` impl (identity/health/listTools/executeTool parity path).
- `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspaceError.swift` — `PKError` cases.
- `Sources/YakamozCore/Workspaces/Terminal/TerminalCommandApproving.swift` — approval protocol + decision enum + `DenyAllApprover` default.
- `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift` — the five `Tool` types.
- `Sources/Yakamoz/Views/TerminalApprovalBanner.swift` — SwiftUI approval prompt.
- `Sources/YakamozCore/Workspaces/Terminal/MainActorApprover.swift` — concrete approver bridging tools → UI via an async stream of pending requests.
- Test files mirroring each under `Tests/YakamozTests/...`.

**Modified:**
- `Sources/YakamozCore/Models/PersistenceModels.swift` — `ConversationModel.attachedWorkspaceIds`; `WorkspaceModel.kind`.
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift` — terminal tool options, multi-attach helpers.
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` — registry ownership, `resolveTools` terminal wiring, approver injection.
- `Sources/Yakamoz/Views/WorkspacePicker.swift`, `ChatView.swift`, `ConversationListView.swift` — multi-attach + "Create & attach Terminal" + approval banner host.
- `project.yml` — SwiftTerm package + `YakamozCore` dependency.

---

# YAK-T1 — Multi-Workspace Attachment

**Outcome:** A conversation can hold several attached workspaces. No terminal yet. Existing single-folder behavior preserved via additive migration.

### Task 1: Add `attachedWorkspaceIds` additively to `ConversationModel`

**Files:**
- Modify: `Sources/YakamozCore/Models/PersistenceModels.swift` (`ConversationModel` ~L42-78)
- Test: `Tests/YakamozTests/ConversationAttachmentTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftData
@testable import YakamozCore

@Suite struct ConversationAttachmentTests {
    @Test func legacyWorkspaceIdFoldsIntoAttachedList() {
        let c = ConversationModel(title: "t")
        c.workspaceId = UUID()
        // allAttachedWorkspaceIds merges legacy single id with the new array
        #expect(c.allAttachedWorkspaceIds == [c.workspaceId!])
    }

    @Test func newAttachmentsUseTheArray() {
        let c = ConversationModel(title: "t")
        let a = UUID(); let b = UUID()
        c.attachedWorkspaceIds = [a, b]
        #expect(Set(c.allAttachedWorkspaceIds) == [a, b])
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `make test TEST_FILTER=ConversationAttachmentTests`
Expected: FAIL — `attachedWorkspaceIds` / `allAttachedWorkspaceIds` not found.

- [ ] **Step 3: Implement (additive field + merge accessor)**

In `ConversationModel`, keep `workspaceId` (do NOT rename — automatic lightweight migration only tolerates additive changes), add:

```swift
/// Multi-attach workspace ids (YAK-T1). `workspaceId` is the deprecated single-attach
/// predecessor, retained only so existing stores migrate without a versioned schema.
public var attachedWorkspaceIds: [UUID] = []

/// Legacy single id folded with the new array; the rest of the app reads this.
public var allAttachedWorkspaceIds: [UUID] {
    var ids = attachedWorkspaceIds
    if let legacy = workspaceId, !ids.contains(legacy) { ids.insert(legacy, at: 0) }
    return ids
}
```

Add `attachedWorkspaceIds` to the initializer with default `[]`.

- [ ] **Step 4: Run, verify pass**

Run: `make test TEST_FILTER=ConversationAttachmentTests` → PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(YAK-T1): add multi-attach workspace ids to ConversationModel"
```

### Task 2: One-time backfill — fold legacy `workspaceId` into the array

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift` (`WorkspaceAttachmentSupport`)
- Test: `Tests/YakamozTests/ConversationAttachmentTests.swift`

- [ ] **Step 1: Failing test** — `backfillLegacyAttachment` moves a non-nil `workspaceId` into `attachedWorkspaceIds` and nils the legacy field; idempotent on second call.
- [ ] **Step 2: Run, verify fails.**
- [ ] **Step 3: Implement** `static func backfillLegacyAttachment(_:)` on `WorkspaceAttachmentSupport`; call it from the conversation-load path (where `makeChatViewModel` is set up in `ChatView.bootstrap`). Guard: no-op when `workspaceId == nil`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(YAK-T1): backfill legacy single workspace attachment`.

### Task 3: Multi-attach/detach in `WorkspaceAttachmentSupport`

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift:80-107`
- Test: `Tests/YakamozTests/ConversationAttachmentTests.swift`

- [ ] **Step 1: Failing test** — attaching a second folder leaves the first attached; `detachWorkspace(id:)` removes only that id and disables only its tool ids; `enabledToolIds` for the remaining workspace are preserved.
- [ ] **Step 2: Run, verify fails.**
- [ ] **Step 3: Implement.** Change signatures:

```swift
// BEFORE: attachWorkspace sets conversation.workspaceId = workspace.id
// AFTER:
public static func attachWorkspace(to conversation: ConversationModel, modelContext: ModelContext, url: URL) -> WorkspaceModel {
    let bookmark = try? url.bookmarkData(options: .withSecurityScope)
    let workspace = WorkspaceModel(displayName: url.lastPathComponent, folderPath: url.path, bookmarkData: bookmark)
    modelContext.insert(workspace)
    conversation.attachedWorkspaceIds.append(workspace.id)
    let selected = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: false)
        .union(FileSystemWorkspace.toolIds)
    conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selected, hasWorkspace: true)
    try? modelContext.save()
    return workspace
}

public static func detachWorkspace(id: UUID, from conversation: ConversationModel, modelContext: ModelContext) {
    conversation.attachedWorkspaceIds.removeAll { $0 == id }
    if conversation.workspaceId == id { conversation.workspaceId = nil }
    // Recompute enabled tools from remaining attachments (folder tools only if a folder remains)
    ... // see Task 4 gating
    try? modelContext.save()
}
```

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(YAK-T1): support attaching and detaching multiple workspaces`.

### Task 4: UI — `WorkspacePicker` and `ChatView` read the list

**Files:**
- Modify: `Sources/Yakamoz/Views/WorkspacePicker.swift`, `Sources/Yakamoz/Views/ChatView.swift:40-58,224-258`, `ConversationListView.swift:114`
- Test: covered by existing view-model tests; add `ChatViewWorkspaceResolutionTests` if a derivation helper is extracted.

- [ ] **Step 1:** Extract a pure helper `attachedWorkspaces(for:in:)` returning `[WorkspaceModel]` from `conversation.allAttachedWorkspaceIds`; write a failing test for it.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** `WorkspacePicker` renders one chip per attached workspace with its own detach button (calls `detachWorkspace(id:)`); "Attach Folder" still appends. `ChatView.workspaceRoot`/`attachedWorkspace` become list-derived (folder workspaces only, for `resolveTools`' `workspaceRoot:` until T4 generalizes it). Update `.task(id:)` invalidation key (L134) to hash `allAttachedWorkspaceIds`.
- [ ] **Step 4:** `make build` then `make test TEST_FILTER=ChatViewModelTests` → PASS.
- [ ] **Step 5: Commit** `feat(YAK-T1): multi-workspace UI in picker and chat view`.

---

# YAK-T2 — Timeline/Workspace State-Consistency Hardening

**Outcome:** Attachment state stays consistent across detach, conversation delete, relaunch, and orphaned-workspace cleanup. Invariant tests. Lands before live session state exists.

### Task 5: Invariant — `enabledToolIds` never references tools whose workspace is gone

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift`
- Test: `Tests/YakamozTests/WorkspaceConsistencyTests.swift` (create)

- [ ] **Step 1: Failing test** — after detaching the only folder workspace, no folder tool ids remain in `enabledToolIds`; with two folders attached, detaching one keeps folder tools enabled (another folder remains).
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement `reconcileEnabledTools(for:attachedWorkspaces:)` that recomputes the enabled set from currently-attached workspace kinds; call it from `detachWorkspace`.
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5: Commit** `feat(YAK-T2): reconcile enabled tools on detach`.

### Task 6: Orphan cleanup — delete `WorkspaceModel` rows no conversation references

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift` (or a new `WorkspaceMaintenance.swift`)
- Test: `Tests/YakamozTests/WorkspaceConsistencyTests.swift`

- [ ] **Step 1: Failing test** — `pruneOrphanWorkspaces(modelContext:)` deletes `WorkspaceModel`s not present in any `ConversationModel.allAttachedWorkspaceIds`, and leaves referenced ones.
- [ ] **Step 2-4:** Implement + run green. Call on launch and after conversation delete.
- [ ] **Step 5: Commit** `feat(YAK-T2): prune orphaned workspace rows`.

### Task 7: Conversation-delete cascades attachment cleanup

**Files:**
- Modify: wherever conversation deletion happens (`ConversationListView` delete action / coordinator)
- Test: `Tests/YakamozTests/WorkspaceConsistencyTests.swift`

- [ ] **Step 1-4:** Failing test that deleting a conversation triggers `pruneOrphanWorkspaces`; implement; green.
- [ ] **Step 5: Commit** `feat(YAK-T2): clean up workspaces when a conversation is deleted`.

---

# YAK-T3 — Terminal Backend (SwiftTerm)

**Outcome:** `TerminalSession` + `TerminalSessionRegistry` working and tested. No agent wiring, no UI.

### Task 8: Add the SwiftTerm dependency

**Files:**
- Modify: `project.yml` (`packages:` ~L18-30, `YakamozCore` `dependencies:` ~L55-66)

- [ ] **Step 1:** Add under `packages:`:

```yaml
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    from: 1.2.0   # confirm latest stable tag at implementation time
```

Add under `YakamozCore` `dependencies:`:

```yaml
      - package: SwiftTerm
        product: SwiftTerm
```

- [ ] **Step 2:** `make generate && make build`.
Expected: builds; `import SwiftTerm` resolves in a YakamozCore file (add a temporary `import SwiftTerm` to confirm, then remove).
- [ ] **Step 3: Commit** `build(YAK-T3): add SwiftTerm dependency`.

### Task 9: `TerminalSession` — spawn a shell on a PTY and run one command

**Files:**
- Create: `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift`
- Create: `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspaceError.swift`
- Test: `Tests/YakamozTests/TerminalSessionTests.swift` (create)

- [ ] **Step 1: Failing test**

```swift
import Testing
@testable import YakamozCore

@Suite struct TerminalSessionTests {
    @Test func runEchoReturnsOutputAndZeroExit() async throws {
        let session = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
        let result = try await session.run("echo hello", graceMs: 4000)
        guard case let .finished(output, code) = result else {
            Issue.record("expected finished, got \(result)"); return
        }
        #expect(output.contains("hello"))
        #expect(code == 0)
        await session.terminate()
    }
}
```

- [ ] **Step 2:** Run, verify fails (type missing).
- [ ] **Step 3: Implement minimal `TerminalSession`.**

Key points (full implementation in this step):
- `actor TerminalSession`. Init starts a `LocalProcess` (SwiftTerm) running `/bin/zsh` with `cwd = rootURL.path`, env merged with `TERM=dumb`. A delegate forwards `dataReceived(slice:)` into the actor's `appendOutput(_:)`.
- Maintain `var buffer: [UInt8]` and `var cursor: Int` (read position).
- `run(_:graceMs:)`: generate `let mark = "MARK-\(UUID().uuidString)"`; write `command + "; printf '\\n\(mark):%s\\n' \"$?\"\n"`; record `pendingMark = mark`; then `await collectUntilMark(graceMs:)`.
- `collectUntilMark` loops with a bounded budget polling for `"\(mark):"` in the decoded buffer; on found, parse trailing int as exit code, slice out output between input echo and the mark line, ANSI-strip, return `.finished`. On budget exhaustion return `.running(outputSoFar)` leaving `pendingMark` set.
- ANSI strip: regex `\u{1B}\[[0-9;?]*[ -/]*[@-~]` removed from captured text.
- `terminate()`: `process.terminate()` / kill the child.

Define `enum RunResult { case finished(String, Int32); case running(String) }` and `TerminalWorkspaceError: PKError` (`sessionSpawnFailed`, `shellExited`, `commandAlreadyRunning`, `notRunning`) with stable `errorCode`s and `userFriendlyMessage`.

- [ ] **Step 4:** Run: `make test TEST_FILTER=TerminalSessionTests` → PASS.
- [ ] **Step 5: Commit** `feat(YAK-T3): TerminalSession runs a command over a PTY`.

### Task 10: Persistent cwd + non-zero exit

- [ ] **Step 1: Failing tests** — `cd /tmp` then `pwd` (second `run`) reports `/tmp`; `run("false")` → exit code `1`.
- [ ] **Step 2-4:** Should already pass given Task 9's design; if not, fix buffer/cursor handling so a second `run` only returns output after the prior cursor. Green.
- [ ] **Step 5: Commit** `test(YAK-T3): persistent cwd and exit-code propagation`.

### Task 11: Non-blocking run + `read`/`wait`

**Files:** `TerminalSession.swift`, `TerminalSessionTests.swift`

- [ ] **Step 1: Failing test**

```swift
@Test func longCommandReturnsRunningThenFinishes() async throws {
    let s = try await TerminalSession(rootURL: URL(fileURLWithPath: "/tmp"))
    let first = try await s.run("sleep 1; echo done", graceMs: 200)
    #expect({ if case .running = first { return true } else { return false } }())
    let final = try await s.wait(timeoutMs: 5000)
    if case let .finished(out, code) = final { #expect(out.contains("done")); #expect(code == 0) }
    else { Issue.record("did not finish") }
    await s.terminate()
}
```

- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement `read()` (returns new bytes since cursor + status, advancing cursor) and `wait(timeoutMs:)` (poll `collectUntilMark` against the outstanding `pendingMark`). Guard `run` while `pendingMark != nil` → throw `.commandAlreadyRunning`.
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5: Commit** `feat(YAK-T3): non-blocking run with read/wait`.

### Task 12: `sendInput` and `interrupt`

- [ ] **Step 1: Failing tests** — `run("read x; echo got:$x", grace 200)` → `.running`; `sendInput("hi\n")`; `wait` → output contains `got:hi`. `run("sleep 100", grace 200)` → `.running`; `interrupt()`; `wait(2000)` → finished with non-zero code.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** `sendInput(_:)` = raw `process.send`; `interrupt()` = `process.send([0x03])`. Ensure interrupt clears `pendingMark` once the shell prints its mark for the interrupted job (the `printf` still runs and reports `$?`).
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5: Commit** `feat(YAK-T3): send input and interrupt`.

### Task 13: Marker-spoof resistance + ANSI stripping

- [ ] **Step 1: Failing tests** — `run("echo 'MARK-fake:0'")` finishes via the *real* random mark, and the fake line appears in output without ending the command early; a command emitting color codes returns clean text.
- [ ] **Step 2-4:** Verify the random-per-command mark and ANSI strip already handle this; adjust if needed. Green.
- [ ] **Step 5: Commit** `test(YAK-T3): marker-spoof resistance and ANSI stripping`.

### Task 14: `TerminalSessionRegistry`

**Files:**
- Create: `Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift`
- Test: `Tests/YakamozTests/TerminalSessionRegistryTests.swift` (create)

- [ ] **Step 1: Failing test** — `session(for:id, rootURL:)` returns the same instance on repeated calls (identity preserved across "timeline switch"); `terminate(id:)` then request → a *new* instance. `allowForSession(id:)` / `isAllowed(id:)` toggles.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement `actor TerminalSessionRegistry` with `private var sessions: [UUID: TerminalSession]`, `private var sessionAllow: Set<UUID>`, `session(for:rootURL:)` lazy-create, `terminate(id:)`, `terminateAll()`, `allowForSession(_:)`, `isAllowed(_:)`.
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5: Commit** `feat(YAK-T3): session registry with lifecycle and session-allow`.

---

# YAK-T4 — TerminalWorkspace + Agent Tools + Approval Seam

**Outcome:** The agent can call the five tools; every `terminal_run` is gated; default-deny when unwired.

### Task 15: `TerminalCommandApproving` + `DenyAllApprover`

**Files:**
- Create: `Sources/YakamozCore/Workspaces/Terminal/TerminalCommandApproving.swift`
- Test: `Tests/YakamozTests/TerminalApprovalTests.swift` (create)

- [ ] **Step 1: Failing test** — `DenyAllApprover().requestApproval(...)` returns `.deny`.
- [ ] **Step 2-4:** Define the protocol, `enum TerminalApprovalDecision { case approve, deny, allowForSession }`, and `struct DenyAllApprover: TerminalCommandApproving`. Green.
- [ ] **Step 5: Commit** `feat(YAK-T4): approval protocol with default-deny`.

### Task 16: The five tools

**Files:**
- Create: `Sources/YakamozCore/Tools/Terminal/TerminalTools.swift`
- Test: `Tests/YakamozTests/TerminalToolsTests.swift` (create)

Use a `MockApprover` (scripted decisions) and a real `TerminalSession`/registry.

- [ ] **Step 1: Failing tests**
  - `TerminalRunTool` with approver returning `.approve` runs `echo hi` → result text contains `hi`; with `.deny` → failure result "denied by user", and (assert) the shell received nothing (use a session spy or check no output produced).
  - `.allowForSession` → registry `isAllowed(id)` becomes true; a second run with the *same* approver set to `.deny` still runs (pre-approved bypass).
  - `TerminalReadTool` / `TerminalWaitTool` reflect status; `TerminalSendInputTool` / `TerminalInterruptTool` do **not** consult the approver.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement five `Tool` types in one file. Each holds `workspaceId`, the `TerminalSessionRegistry`, and `rootURL`; `TerminalRunTool` also holds the `any TerminalCommandApproving`. `terminal_run` flow:

```swift
if await !registry.isAllowed(workspaceId) {
    switch await approver.requestApproval(command: cmd, workspaceId: workspaceId) {
    case .deny: return .failure("Command denied by user.")
    case .allowForSession: await registry.allowForSession(workspaceId); fallthrough
    case .approve: break
    }
}
let session = try await registry.session(for: workspaceId, rootURL: rootURL)
let result = try await session.run(cmd, graceMs: 2000)
return .success(render(result))   // include status + exitCode in the text payload
```

Define tool ids exactly: `terminal_run`, `terminal_read`, `terminal_send_input`, `terminal_interrupt`, `terminal_wait`.

- [ ] **Step 4:** Run: `make test TEST_FILTER=TerminalToolsTests` → PASS.
- [ ] **Step 5: Commit** `feat(YAK-T4): five terminal tools gated by approval`.

### Task 17: `TerminalWorkspace` (`WorkspaceProtocol`)

**Files:**
- Create: `Sources/YakamozCore/Workspaces/Terminal/TerminalWorkspace.swift`
- Modify: `../PositronicKit/Sources/PKShared/SharedTypes/WorkspaceURI.swift` (add `static func terminal(rootPath:) -> WorkspaceURI` returning host `pk-terminal`) — **PositronicKit change; update its call sites/docs in the same commit per repo convention.**
- Test: `Tests/YakamozTests/TerminalWorkspaceTests.swift` (create)

- [ ] **Step 1: Failing test** — `listTools()` returns the five ids; `readFile` throws `toolExecutionNotSupported`; `reference.location == .attached`, `rootPath` set, `trustLevel == .full`.
- [ ] **Step 2-4:** Implement mirroring `FileSystemWorkspace` shape; `executeTool` routes ids to the same tool types (parity path) using the registry. Green.
- [ ] **Step 5: Commit** `feat(YAK-T4): TerminalWorkspace identity and parity routing`.

### Task 18: Persistence `kind` + tool options + `resolveTools` wiring

**Files:**
- Modify: `Sources/YakamozCore/Models/PersistenceModels.swift` (`WorkspaceModel` ~L182, add `kind`)
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift` (terminal options + `requiresTerminal`)
- Modify: `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`resolveTools` ~L110; registry field; `makeChatViewModel` ~L166)
- Test: `Tests/YakamozTests/TerminalToolGatingTests.swift` (create)

- [ ] **Step 1: Failing tests**
  - `WorkspaceModel(kind: .terminal)` default for existing rows is `.folder` (decode-compat: `public var kind: WorkspaceKind = .folder`).
  - `ConversationToolSupport.toolOptions(hasWorkspace:hasTerminal:)` includes the five terminal ids only when `hasTerminal`.
  - `resolveTools(enabledToolIds:workspaceRoot:terminals:)` appends terminal `AnyTool`s only for attached terminals and respects the `enabledToolIds` filter.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement:
  - `WorkspaceKind` enum + field (additive → lightweight migration).
  - Extend tool-option API with a terminal gate (parallel to `requiresWorkspace`).
  - `YakamozRuntime` gains `let terminalRegistry = TerminalSessionRegistry()` and an injected `any TerminalCommandApproving` (default `DenyAllApprover()`); extend `resolveTools` signature with `terminals: [TerminalToolContext]` (`struct TerminalToolContext { let workspaceId: UUID; let rootURL: URL }`) and append the five tools per context. Thread `terminals` through `makeChatViewModel`.
- [ ] **Step 4:** `make build` + `make test TEST_FILTER=TerminalToolGatingTests` → PASS.
- [ ] **Step 5: Commit** `feat(YAK-T4): terminal persistence kind, tool gating, resolveTools wiring`.

---

# YAK-T5 — Workspaces-Tab UI + Approval Prompt

**Outcome:** User can create+attach a terminal from a folder workspace and approve/deny commands live.

### Task 19: `MainActorApprover` bridging tools → UI

**Files:**
- Create: `Sources/YakamozCore/Workspaces/Terminal/MainActorApprover.swift`
- Test: `Tests/YakamozTests/TerminalApprovalTests.swift`

- [ ] **Step 1: Failing test** — enqueuing a request exposes a pending item; resolving it with `.approve` completes the awaiting `requestApproval` call with `.approve`. (Drive both sides with continuations; no sleeps.)
- [ ] **Step 2-4:** Implement an `@MainActor`-observable approver: `requestApproval` appends a `PendingApproval { command, workspaceId, continuation }` to a published array and suspends; `resolve(_:with:)` removes it and resumes. Green.
- [ ] **Step 5: Commit** `feat(YAK-T5): main-actor approval bridge`.

### Task 20: `TerminalApprovalBanner` + host in `ChatView`

**Files:**
- Create: `Sources/Yakamoz/Views/TerminalApprovalBanner.swift`
- Modify: `Sources/Yakamoz/Views/ChatView.swift` (host banner; pass the runtime's `MainActorApprover` pending list)

- [ ] **Step 1:** Banner shows `command`, with Approve / Deny / "Allow for this terminal" buttons calling `approver.resolve(_:with:)`. No unit test (pure view); verify via `make build`.
- [ ] **Step 2:** Wire `YakamozRuntime` to construct a `MainActorApprover`, hand it to `resolveTools` for `terminal_run`, and expose its pending list to `ChatView`.
- [ ] **Step 3:** `make build`.
- [ ] **Step 4: Commit** `feat(YAK-T5): approval banner wired to terminal tools`.

### Task 21: "Create & attach Terminal" affordance

**Files:**
- Modify: `Sources/Yakamoz/Views/WorkspacePicker.swift`
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift` (`attachTerminal(to:fromFolder:modelContext:)`)
- Test: `Tests/YakamozTests/ConversationAttachmentTests.swift`

- [ ] **Step 1: Failing test** — `attachTerminal(to:fromFolder:)` inserts a `WorkspaceModel(kind: .terminal, folderPath: folder.folderPath)`, appends its id to `attachedWorkspaceIds`, and enables the five terminal tool ids.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Implement the helper; add a per-folder-chip menu action "Create Terminal" in `WorkspacePicker` that calls it. Terminal chips render with a distinct icon and a detach button (detach also calls `terminalRegistry.terminate(id:)` via the runtime).
- [ ] **Step 4:** `make build` + `make test TEST_FILTER=ConversationAttachmentTests` → PASS.
- [ ] **Step 5: Commit** `feat(YAK-T5): create and attach a terminal from a folder workspace`.

### Task 22: Lifecycle teardown on app quit + README note

**Files:**
- Modify: `Sources/Yakamoz/YakamozApp.swift` (call `runtime.terminalRegistry.terminateAll()` on termination)
- Modify: `README.md` (safety/tradeoff note alongside the non-sandbox section)

- [ ] **Step 1:** Hook app-termination to `terminateAll()`; document the unjailed-shell tradeoff + per-command approval mitigation in README.
- [ ] **Step 2:** `make verify` (full gate, asserts non-zero executed test count).
- [ ] **Step 3: Commit** `feat(YAK-T5): terminate sessions on quit; document terminal safety tradeoff`.

---

## Final Verification

- [ ] `make verify` passes (non-zero tests executed).
- [ ] Manual smoke (Xcode run): attach a folder → "Create Terminal" → ask the agent to run `pwd && ls`; confirm the approval banner appears, Approve runs it, Deny blocks it, output shows in the Tools inspector tab; switch timelines and back, confirm `cd /tmp` persisted; `sleep 5 &`-style long command returns control and `terminal_read` shows completion.

## Risks / Watch-items

- **SwiftTerm `LocalProcess` API surface** — confirm the exact delegate method names and the spawn signature (`startProcess(executable:args:environment:)` vs the view helper) against the installed version before Task 9; adjust the wrapper accordingly.
- **`zsh` startup noise** — a login shell may emit rc-file output; the first `run` should drain anything before the first mark. If startup banners leak, prefer `/bin/zsh -f` (no rc files) or drain-until-first-prompt at init.
- **Grace period tuning** — 2s default for `terminal_run`; expose as a parameter so tests can use short budgets.
