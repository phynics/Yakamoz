# YAK-TF6 — Minor cleanup: orphan row on detach, fire-and-forget quit teardown, dead error case

**Status:** Done
**Severity:** 🟢 Low (housekeeping)
**Area:** Terminal workspace — lifecycle / hygiene
**Source:** Integration review of merge `78a7b7f`

> **Resolution.** `WorkspaceAttachmentSupport.detachWorkspace` now returns pruned
> terminal workspace ids and immediately prunes any newly orphaned `WorkspaceModel`
> rows, so detach cleanup matches `deleteConversation` instead of waiting for a later
> sweep. `WorkspacePicker` now tears down live terminal sessions from that returned
> id list, and `YakamozApp`'s quit comment explicitly documents that `willTerminate`
> teardown is fire-and-forget and relies on macOS/PTTY cleanup if it loses the race.
> Added detach tests for orphan pruning and shared-reference retention. Focused
> verification passed with `make test TEST_FILTER=WorkspaceConsistencyTests`.

Three small, independent items grouped into one ticket. Each can be a separate
commit.

---

## 6a. Detached terminal leaves an orphaned `WorkspaceModel` row

`WorkspaceAttachmentSupport.detachWorkspace(id:from:modelContext:)` removes the id
from `attachedWorkspaceIds` and reconciles tools, and the picker correctly
terminates the live session (`WorkspacePicker.detach(_:)`). But the now-unreferenced
`WorkspaceModel` row is never deleted; it lingers until the next
`pruneOrphanWorkspaces` (app launch / a later conversation delete).

**Affected:** `Sources/YakamozCore/Tools/ConversationToolSupport.swift`
(`detachWorkspace(id:)`).

**Fix:** after detaching, prune the row if it is no longer referenced by any
conversation, and return any pruned **terminal** ids so the caller can also tear
down the session in one place (mirrors `deleteConversation`'s contract):

```swift
@discardableResult
public static func detachWorkspace(id: UUID, from conversation: ConversationModel, modelContext: ModelContext) -> [UUID] {
    conversation.attachedWorkspaceIds.removeAll { $0 == id }
    if conversation.workspaceId == id { conversation.workspaceId = nil }

    let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<WorkspaceModel>())) ?? []
    let remainingWorkspaces = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)
    reconcileEnabledTools(for: conversation, attachedWorkspaces: remainingWorkspaces)

    return pruneOrphanWorkspaces(modelContext: modelContext) // saves; returns pruned terminal ids
}
```

Then `WorkspacePicker.detach(_:)` can terminate sessions off the returned ids
instead of inferring `isTerminal` locally. (Keep behavior identical for folder
workspaces.)

**Acceptance:** detaching a workspace leaves no unreferenced `WorkspaceModel` row.

---

## 6b. `willTerminate` teardown is fire-and-forget

```swift
// Sources/Yakamoz/YakamozApp.swift  (NSApplication.willTerminateNotification)
Task { await runtime.terminalRegistry.terminateAll() }
```

The detached `Task` is not awaited, so termination usually races the process
exit and does not complete. The comment already calls this "best-effort," and
closing the PTY master typically SIGHUPs the child shell — so this is genuinely
low risk. If we want the clean path to actually run, drive teardown synchronously
via `NSApplicationDelegate.applicationShouldTerminate(_:)` returning
`.terminateLater` and calling `reply(toApplicationShouldTerminate: true)` after
`terminateAll()` completes.

**Decision needed:** accept best-effort (document and close), or implement the
`terminateLater` handshake. Recommend: accept as-is given SIGHUP, just confirm in
a comment that the OS path is relied upon.

---

## 6c. `.notRunning` is dead code (until YAK-TF1)

`TerminalWorkspaceError.notRunning` (`TerminalWorkspaceError.swift:13`) is defined
but never thrown. **YAK-TF1's fix makes it reachable** (it's the guard for
`sendInput` on an idle session). No action here beyond YAK-TF1 — listed only so
a linter/dead-code sweep does not remove it before TF1 lands.

**Acceptance:** after YAK-TF1, `.notRunning` is thrown and covered by a test.
