# YAK-8 — UI to show/toggle available tools ("skills")

- **Status:** Done
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** post-CP11 follow-up request

> **Resolved.** `ConversationToolSupport` enumerates demo + (workspace-gated)
> filesystem tools; the Tools inspector tab (`ToolsInspectorView`) renders a
> `Toggle` per tool bound to `conversation.enabledToolIds` via `onSetToolEnabled`,
> with empty = "all enabled" semantics and a guard against disabling the last
> remaining tool. Toggling flows through `toolSyncKey`/`refreshViewModelTools`.

## Problem

A conversation's available tool set is driven entirely by
`ConversationModel.enabledToolIds` (`[String]`), resolved via
`YakamozRuntime.resolveTools(enabledToolIds:workspaceRoot:)`
(`Sources/YakamozCore/Runtime/YakamozRuntime.swift:97`). Today there is no UI
to see or change this list directly:

- Demo tools (`CalculatorTool`, `CurrentDateTimeTool`) are always available
  and never surfaced to the user as a toggle.
- Filesystem tools (`ReadFileTool`/`ListDirectoryTool`/`FindFileTool`/
  `SearchFilesTool`/`SearchFileContentTool`/`ChangeDirectoryTool`) only appear
  when a workspace folder is attached (see [YAK-3](YAK-3-workspace-tools-mid-conversation.md)),
  with no way to disable them individually while a workspace is attached, or
  enable them without attaching a folder.
- `enabledToolIds` itself has no editor — if it's non-empty, `resolveTools`
  filters down to only those ids (`YakamozRuntime.swift:115-117`), but nothing
  in the UI ever populates it that way.

## Proposed approach

Add a tools/skills picker, analogous to `PersonaPicker`/`WorkspacePicker`
(`Sources/Yakamoz/Views/ChatView.swift:73-83`):

- A toolbar item (or inspector tab) listing every tool `resolveTools` can
  produce (demo tools always; filesystem tools only when a workspace is
  attached), each with a toggle bound to `conversation.enabledToolIds`.
- When `enabledToolIds` is empty, treat it as "all available tools enabled"
  (matches current `resolveTools` semantics) rather than "none enabled," to
  avoid silently breaking existing conversations.
- Wire into the existing `toolSyncKey`/`refreshViewModelTools()` mechanism
  (`ChatView.swift:91-93, 125-128, 239-246`) so toggling takes effect
  immediately without rebuilding the view model.

## Acceptance criteria
- User can see which tools are currently enabled for a conversation and toggle
  them individually.
- Toggling takes effect on the next send, without reopening the conversation.
- Existing conversations with empty `enabledToolIds` keep behaving as "all
  tools available" by default.
- Covered by a headless test on the tool-resolution/toggle path.

## Pointers
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`resolveTools`)
- `Sources/YakamozCore/Models/PersistenceModels.swift` (`ConversationModel.enabledToolIds`)
- `Sources/Yakamoz/Views/ChatView.swift` (`toolSyncKey`, `refreshViewModelTools`, toolbar items)
- [YAK-3](YAK-3-workspace-tools-mid-conversation.md) (workspace-triggered tool re-wiring this UI sits alongside)
