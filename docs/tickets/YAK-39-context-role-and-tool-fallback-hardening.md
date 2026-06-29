# YAK-39 - [SECURITY] Follow up prompt-context role elevation and text tool fallback

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

The scan left two prompt-safety rows as follow-up rather than final reportable findings:

1. Retrieved notes, memories, and workspace context can be projected into provider
   system messages.
2. When structured tool calls are absent, assistant text is parsed for `<tool_call>` /
   JSON fallback calls and routed into normal tool execution.

These behaviors may be intentional compatibility features, but Yakamoz is specifically a
"prompt pipeline under glass" app and should make this boundary explicit. Untrusted
workspace notes should not gain hidden/system-level authority, and fallback text tool
calls should not bypass whatever tool approval model YAK-31 lands.

## Affected code

- `../PositronicKit/Sources/PositronicKit/Services/Prompting/RenderedPromptProjection.swift`
- `../PositronicKit/Sources/PositronicKit/Services/Prompting/Prompt+OpenAI.swift`
- `../PositronicKit/Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift:31`
- `../PositronicKit/Sources/PositronicKit/Utilities/ToolOutputParser.swift`
- Yakamoz inspector prompt sections and tool trace views

## Before / after

### Before

```swift
let fallbackCalls = ToolOutputParser.parse(from: await context.outputs.fullResponse)
```

and context sections may be merged into the provider system-message projection.

### After

```swift
guard fallbackToolCallsAreEnabled(for: provider, tools: context.availableTools) else {
    return noFallbackCalls()
}

let fallbackCalls = ToolOutputParser.parse(from: await context.outputs.fullResponse)
```

Context role handling should be reviewed separately: either keep untrusted retrieved
content below system instructions or make the role elevation visible and justified in
Yakamoz's inspector.

## Tests

- Prompt projection tests show untrusted retrieved context is not merged with root system instructions unless explicitly intended.
- Fallback text tool-call tests prove fallback calls pass through the same approval and permission gates as structured calls.
- Yakamoz inspector tests show section roles clearly enough to distinguish system, context, user, and tool content.
- Provider compatibility tests cover the fallback behavior for models that need it.

## Acceptance criteria

- The team has an explicit policy for retrieved context role projection.
- Yakamoz's inspector makes that policy visible to users.
- Text fallback tool calls cannot bypass YAK-31's approval gate.
- Any provider-specific fallback remains covered by tests and can be disabled if unsafe.
- PositronicKit verification and Yakamoz `make verify` are green.
