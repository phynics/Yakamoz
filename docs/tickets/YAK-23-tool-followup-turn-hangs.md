# YAK-23 — [BUG] A turn that invokes a tool hangs forever (follow-up LLM round never ends)

- **Status:** Done (diagnosed)
- **Priority:** High
- **Repos:** Yakamoz + PositronicKit (engine/provider)
- **Surfaced by:** real-provider testing (2026-06-25), after YAK-19 made tools actually execute

## Symptom

With a valid API key, plain replies stream fine, but any turn that triggers a tool call
(e.g. "what is 19273 × 4412?" → calculator) leaves the assistant bubble spinning forever
— no response, no error, no completion.

## What's been ruled out

- **API key:** present; non-tool replies work.
- **UI / reducer / view-model:** the headless test
  `toolCallSucceedsWithoutAttachedWorkspace` drives a full scripted tool
  call → result → final reply through `ChatViewModel`/`ChatEventReducer` and terminates
  correctly. So consume/reduce is not the cause.
- **Tool execution itself:** `ToolRouter.executeWithTimeout` caps tool runs at 60s, so a
  stuck tool would self-resolve — it cannot produce an *infinite* spinner.
- **Engine loop bound:** `ChatEngine.execute` runs `while turnCount < maxTurns` then
  `continuation.finish()`, so the loop is bounded; infinity can only come from a single
  `runOneTurn` whose LLM stream never terminates.

## Evidence update (2026-06-25)

A later run completed normally with **no tool loop** — logs showed `Starting turn 1`,
then the assistant answered directly and finished. The model answered the arithmetic
inline without calling the calculator, so the follow-up round was never reached and there
was no hang. This corroborates the hypothesis: the hang is specific to the post-tool
follow-up round, reached only when a tool is *actually* invoked. Reproduce with a prompt
the model cannot answer without a tool (e.g. "what is the current date and time?" →
`current_datetime`). Also observed: `Context gathered in 4.939s` on an empty conversation
— unrelated perf smell, track separately if it persists.

## Mitigation update (2026-06-25)

Added a per-stream watchdog in `LLMStreamingStage`, wired through `ChatEngine.Dependencies`
with a 60s production default and a focused regression test for a post-tool follow-up
stream that never terminates. This prevents an infinite spinner by surfacing a pipeline
error with the underlying `ChatEngineError.streamTimedOut` cause. The ticket remains open:
the live-provider root cause still needs reproduction/log capture to determine whether
the follow-up request shape or provider SSE termination handling is wrong.

## ROOT CAUSE FOUND (2026-06-25) — model incompatibility, not a code bug

Diagnostic logs (commit `74eecac`) with `deepseek/deepseek-v4-flash` via OpenRouter:

```
OpenRouter stream complete (deepseek-v4-flash): finishedWithToolCalls=false sawStreamedToolCalls=false yieldedAnything=false toolsAdvertised=8
Turn 1: no tool calls; assistant content chars=0
```

The model returns a **completely empty completion when tools are advertised** — no
content, no tool call. The same model returns content fine when `toolsAdvertised=0` (an
auxiliary context-stage call in the same trace yielded content). So:
- Yakamoz wiring is correct (8 tools advertised).
- The OpenRouter adapter is correct (advertises tools, parses the response).
- **DeepSeek v4 Flash simply returns empty output when a `tools` array is present** — a
  model/provider compatibility issue.

No infinite hang was ever reproduced in this round; the earlier hang report was either
transient or is now covered by the per-stream watchdog (Mitigation update above). The
"tools don't work" symptom is entirely the empty-completion behavior above.

**Resolution:** tool calling requires a tool-capable model (e.g. `openai/gpt-4o`,
`anthropic/claude-3.5-sonnet`). Two genuine product gaps this exposed are split out:
[YAK-24] (surface empty responses) and [YAK-25] (context-assembly LLM call latency).
Closing YAK-23 as diagnosed; watchdog mitigation retained.

## Hypothesis

The follow-up LLM streaming round — the request the engine issues *after* executing the
tool, carrying the assistant tool-call message + the tool-result message — never receives
a stream terminator from the live provider (or the client never detects end-of-stream for
that response), so `for try await event in stream` in `ChatEngine.runOneTurn` blocks
forever. This path was never exercised before YAK-19 (tool calls used to fail fast at
`toolNotFound`), so it's a latent bug newly exposed, not a regression introduced by it.

## Diagnosis step (needed)

Reproduce with logging (run from Xcode, or Console.app filtered to process `Yakamoz` /
subsystem `com.positronickit.core`) and capture the last lines. Determine which stage
stalls:
- tool execution (`Executing locally:` with no following `Success:`),
- issuing the follow-up (`Success:` but no `Starting turn 2`),
- or streaming the follow-up response (`Starting turn 2` then silence — most likely).

## Likely fix areas
- The construction of the follow-up request's messages (assistant tool_calls + tool
  result) for the active provider — verify it matches the provider's expected
  tool/function-calling message shape so the provider actually closes the stream.
- Provider stream end-of-stream detection for tool-result follow-ups
  (`PKOpenAIProvider`/`PKOpenRouterProvider` client `chatStream`).

## Defensive fix (regardless of root cause)
Add an overall per-turn / per-stream watchdog timeout in the run path so a stalled
provider stream surfaces an inline error instead of an infinite spinner. This is
headlessly testable (script a `MockLLMService` whose follow-up stream never finishes and
assert the run errors after the timeout) and protects the UX even if a provider misbehaves.

## Pointers
- `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine.swift` (`runOneTurn` line ~285 `for try await event in stream`, the `.continueWith` loop branch)
- `../PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift` (`executeLocally`, `executeWithTimeout`)
- `../PositronicKit/Sources/PKOpenAIProvider/OpenAIClient.swift` (`chatStream`, end-of-stream handling)
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` (`run`; currently passes `promptAssemblyLogger: nil` — wire a logger to aid diagnosis)
- `Sources/YakamozCore/Chat/ChatViewModel.swift` (`consume`; where a watchdog timeout would surface)
