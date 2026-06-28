# YAK-TF5 — Approval banner is app-global, not scoped to the visible conversation

**Status:** Done
**Severity:** 🟢 Low (UX / wrong-context approval; multi-conversation only)
**Area:** Terminal workspace — approval UI
**Source:** Integration review of merge `78a7b7f`

> **Resolution.** Added `MainActorApprover.pendingApproval(for:)` so approval selection can be
> scoped by terminal workspace id, then threaded the active conversation's terminal workspace ids
> from `ChatView` into `TerminalApprovalBanner`. Added
> `pendingApprovalForWorkspaceIDsIgnoresOtherConversations`, which verifies one conversation only
> surfaces and resolves its own terminal approval even when another conversation has an older
> pending request. Focused verification passed with
> `make test TEST_FILTER=TerminalApprovalTests`.

## Problem

`MainActorApprover` is a single app-level instance shared by the whole runtime.
`TerminalApprovalBanner` renders `approver.pending.first` with no filter on the
conversation currently on screen.

```swift
// Sources/Yakamoz/Views/TerminalApprovalBanner.swift:12
if let pending = approver.pending.first {  // global oldest, any conversation
```

```swift
// Sources/Yakamoz/Views/ChatView.swift:130
if let terminalApprover, !terminalApprover.pending.isEmpty {
    TerminalApprovalBanner(approver: terminalApprover)
}
```

With two conversations each running a terminal, conversation A's `ChatView` can
display — and let the user approve — a `terminal_run` request that actually
belongs to conversation B (whichever was enqueued first). The user approves a
command they cannot see in context.

The data needed to scope it already exists: `PendingApproval.workspaceId`
(`MainActorApprover.swift:4`) and `conversation.allAttachedWorkspaceIds`.

## Affected code

- `Sources/Yakamoz/Views/TerminalApprovalBanner.swift:12`
- `Sources/Yakamoz/Views/ChatView.swift:130`

## Fix

Pass the current conversation's terminal workspace ids to the banner and select
the first pending request whose `workspaceId` is among them.

### `ChatView.swift` — before

```swift
if let terminalApprover, !terminalApprover.pending.isEmpty {
    TerminalApprovalBanner(approver: terminalApprover)
}
```

### after

```swift
if let terminalApprover {
    TerminalApprovalBanner(
        approver: terminalApprover,
        workspaceIds: Set(attachedTerminalWorkspaces.map(\.id))
    )
}
```

### `TerminalApprovalBanner.swift` — before

```swift
struct TerminalApprovalBanner: View {
    let approver: MainActorApprover
    var body: some View {
        if let pending = approver.pending.first {
```

### after

```swift
struct TerminalApprovalBanner: View {
    let approver: MainActorApprover
    let workspaceIds: Set<UUID>
    var body: some View {
        if let pending = approver.pending.first(where: { workspaceIds.contains($0.workspaceId) }) {
```

## Tests (add)

- Enqueue approvals for two workspace ids; a banner scoped to id A surfaces only
  A's request and `resolve` only affects A's continuation.

## Acceptance criteria

- A conversation's banner only ever shows/resolves approval requests for terminals
  attached to that conversation.
