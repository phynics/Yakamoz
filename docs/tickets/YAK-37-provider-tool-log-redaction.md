# YAK-37 - [SECURITY] Provider and tool debug logs can capture raw sensitive payloads

- **Status:** Open
- **Priority:** Low
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

Several logs include raw provider or tool payloads:

- OpenRouter decode failures log the full raw SSE data string.
- Tool-call extraction debug logging includes full accumulated tool arguments.
- The deprecated streaming coordinator logs raw streamed deltas.

These values can contain prompts, retrieved context, paths, tool arguments, or provider
content. Yakamoz is local-only, but it still uses Console/log streams while handling
user content and API interactions.

## Affected code

- `../PositronicKit/Sources/PKOpenRouterProvider/OpenRouterClient.swift:468`
- `../PositronicKit/Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift:25`
- `../PositronicKit/Sources/PositronicKit/Services/LLM/StreamingCoordinator.swift:58`
- Yakamoz logging configuration and any prompt assembly log toggles

## Before / after

### Before

```swift
logger.error("Failed to decode OpenRouter chunk: \(error.localizedDescription). Raw: \(dataString)")
logger.debug("  [accumulator \(index)] id=\(acc.callId) name=\(String(reflecting: name)) args=\(String(reflecting: acc.args))")
```

### After

```swift
logger.error("Failed to decode OpenRouter chunk: \(error.localizedDescription). payloadBytes=\(data.count) payloadHash=\(hash(dataString))")
logger.debug("  [accumulator \(index)] id=\(acc.callId) name=\(String(reflecting: name)) argsBytes=\(acc.args.utf8.count)")
```

Use a shared redaction/truncation helper if a short preview is still needed for local
debugging.

## Tests

- Redaction helper removes API keys, bearer tokens, prompt text, and large tool arguments.
- Provider decode-error tests assert raw payload text is not logged.
- Tool extraction tests assert argument values are not logged directly.
- Yakamoz debug logging does not opt into raw provider/tool payloads by default.

## Acceptance criteria

- Raw provider chunks and tool arguments are not interpolated into normal logs.
- Any developer-only raw logging requires an explicit local-only opt-in.
- Logs retain enough metadata to debug failures: byte count, hash, model/provider, and error.
- PositronicKit verification and Yakamoz `make verify` are green.
