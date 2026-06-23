# YAK-3 — Re-wire tools when a workspace is attached mid-conversation

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** CP9 / Task 9 (folder workspaces)

## Problem

`ChatView` builds its `ChatViewModel` once on conversation open
(`buildViewModelIfNeeded`, keyed `.task(id: conversation.id)`), passing the current
`enabledToolIds` + `workspaceRoot`. The view model's `tools` are fixed at that point.

When the user attaches a folder **mid-conversation** (`WorkspacePicker` →
`conversation.workspaceId` changes), the `.task(id: conversation.workspaceId)` task
only refreshes the Workspace-tab presentation — it does **not** rebuild the view
model — so the newly-enabled filesystem tools are not offered until the conversation
is reopened.

## Proposed approach

When `conversation.workspaceId` (or `enabledToolIds`) changes, re-resolve the view
model's tool set. Options:
- Add a method on `ChatViewModel` to update `tools` in place (cleanest — preserves
  the in-memory transcript), fed by `runtime.resolveTools(...)`; call it from the
  workspace-change task; **or**
- Rebuild the view model (simpler, but resets in-memory transcript — note the engine
  still has the persisted messages, and `makeChatViewModel` already loads the initial
  transcript).

Prefer the in-place update so attaching a folder takes effect immediately without
losing transcript state.

## Acceptance criteria
- Attach a folder mid-conversation → the next sent message can use the filesystem
  tools, without reopening the conversation.
- Detach → those tools are removed.
- Covered by a headless test on the runtime/view-model tool resolution path.

## Pointers
- `Sources/Yakamoz/Views/ChatView.swift` (`buildViewModelIfNeeded`, `refreshWorkspacePresentation`, the two `.task` modifiers)
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`resolveTools`, `makeChatViewModel`)
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`tools`)
