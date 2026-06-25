# YAK-19 — [BUG] Tool calls not working; no streaming UI indicator

- **Status:** Open
- **Priority:** High
- **Repos:** Yakamoz (+ investigate PositronicKit execution path)
- **Surfaced by:** field feedback (2026-06-25)

## Problem

Two distinct issues observed when a conversation should invoke a tool:
1. **Functional:** tool calls don't actually work (the tool doesn't run / its result
   doesn't come back into the turn).
2. **UX:** there is no UI indicator that a tool is being called or has run.

## Investigation needed (functional)

Trace the path end to end and find where it breaks:
- Are tools actually reaching the provider as tool definitions? `ChatViewModel.run`
  passes `tools:`; `YakamozRuntime.resolveTools` builds them; confirm they survive into
  `kit.run` and become `LLMToolDefinition`s for the active provider.
- Does the engine emit `.toolExecution` / `.generationCompleted` events that the reducer
  consumes (`ChatEventReducer.reduce` handles `.delta(.toolExecution)` /
  `.completion(.toolExecution)`)?
- Does the tool-resolution loop actually execute the tool (`ToolExecutionStage` /
  `ToolRouter`) and feed the output back for the next round-trip?
- Check provider support: some providers need a specific tool/function-calling format;
  verify the configured preset (OpenAI/OpenRouter/Ollama) is one that supports it.

## UI indicator
- `ChatEventReducer` currently treats `.delta(event: .toolCall)` as a no-op, so there's no
  "calling `<tool>`…" affordance while a call forms/executes. Surface in-progress
  (`ToolTraceState.attempting`) and completed (`.succeeded`/`.failed`) traces in the
  transcript and/or composer area — not only in the Tools inspector tab — so the user sees
  tool activity inline.

## Acceptance criteria
- A prompt that needs the calculator/datetime tool actually invokes it and incorporates
  the result into the reply.
- The UI shows tool activity (in progress + outcome) inline during the turn.
- A test exercises a tool-invoking turn through the reducer/view model and asserts a tool
  trace reaches `.succeeded` and the response reflects the tool output.

## Pointers
- `Sources/YakamozCore/Chat/ChatEventReducer.swift` (`reduce`, `applyToolStatus`, the `.delta(.toolCall)` no-op at the switch)
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`run`, `tools`, `toolTraceDTOs`)
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`resolveTools`, `run` → `kit.run`)
- `../PositronicKit/Sources/PositronicKit/Services/Chat/` (`ToolExecutionStage`, `ToolRouter`)
- `Sources/Yakamoz/Views/MessageBubble.swift`, `Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift` (where traces render today)
