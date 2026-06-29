# YAK-34 - [SECURITY] External tool outputs can be forged into timeline history

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

`PositronicKit.run(... toolOutputs:)` accepts caller-supplied `ToolOutputSubmission`
values containing only `toolCallId` and `output`. `ChatEngine.saveConversationSteps`
persists every submitted value as a `.tool` message without checking that the timeline
has a pending deferred assistant tool call with that id.

In Yakamoz this can poison local conversation history if any UI path, plugin, or future
external-tool callback forwards unvalidated tool outputs.

## Affected code

- `../PositronicKit/Sources/PKShared/SharedTypes/ToolOutputSubmission.swift:3`
- `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine+ContextBuilding.swift:180`
- `Sources/YakamozCore/Chat/ChatViewModel.swift`
- `Sources/YakamozCore/Persistence/MessageStore.swift`

## Before / after

### Before

```swift
for output in toolOutputs {
    let msg = ConversationMessage(
        timelineId: timelineId,
        role: .tool,
        content: output.output,
        toolCallId: output.toolCallId
    )
    try await dependencies.messageStore.saveMessage(msg)
}
```

### After

```swift
for output in toolOutputs {
    guard try await pendingToolCalls.consume(output.toolCallId, timelineId: timelineId) else {
        throw ToolError.unmatchedToolOutput(output.toolCallId)
    }
    try await dependencies.messageStore.saveMessage(output.toConversationMessage(timelineId: timelineId))
}
```

The implementation can use a different state model, but it must bind each external tool
output to a pending, unconsumed tool call for the same timeline.

## Tests

- Submitting `toolOutputs` with no pending call is rejected.
- Duplicate submission for the same call id is rejected.
- Valid external tool completion still resumes the conversation.
- Yakamoz history reload does not accept fabricated tool-role messages through its public runtime path.

## Acceptance criteria

- Unmatched or duplicate external tool outputs cannot be persisted.
- Tool outputs are bound to timeline id, tool-call id, and pending-call state.
- Yakamoz has no local path that can inject forged tool outputs into persisted history.
- PositronicKit verification and Yakamoz `make verify` are green.
