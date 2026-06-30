# YAK-42 - PositronicKit: pipeline log-level fidelity + structured metadata

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit (+ Monad/Shuttle if they consume `PipelineLogLevel`)
- **Spec:** `../../Yakamoz/docs/superpowers/specs/2026-06-30-logging-debuggability-design.md`
- **Related:** YAK-41 (do first — label foundation), YAK-40, YAK-37 (redaction)

## Problem

Two gaps make PK logs low-signal for correlating a specific failing interaction:

1. **Level collapse.** `PipelineLogLevel` has only `.debug, .error`
   (`Sources/PKShared/Utilities/Pipeline.swift:5`), so `Pipeline.withLogger`
   (`Sources/PKShared/Utilities/Pipeline+Logging.swift`) maps every pipeline event into one of
   two swift-log levels. Stage timing/info is forced to `.debug`; recoverable issues are forced
   to `.error`. No `.info`/`.notice`/`.warning`.
2. **No structured metadata.** No call site passes swift-log `metadata:`; all context is
   string-interpolated, so logs can't be filtered/correlated by conversation, turn, tool, or
   provider in Console.app.

## Affected code

- `Sources/PKShared/Utilities/Pipeline.swift:5` (`PipelineLogLevel`), `:132/140/145` (emit sites)
- `Sources/PKShared/Utilities/Pipeline+Logging.swift` (level mapping)
- Chat stages: `Services/Chat/Stages/LLMStreamingStage.swift`, `ToolCallExtractionStage.swift`,
  `MessagePersistenceStage.swift`, `Services/Chat/ChatTurnPipelineBuilder.swift`
- Tool routing: `Services/Tools/ToolRouter.swift`, `Services/Tools/ToolTurnProjector.swift`
- Provider/retry: `Utilities/RetryPolicy.swift`, provider adapters

## Before / after

### Before

```swift
public enum PipelineLogLevel: Sendable { case debug, error }

// Pipeline+Logging.swift
switch level {
case .debug: logger.debug("\(message)")
case .error: logger.error("\(message)")
}

// e.g. ToolCallExtractionStage — no correlation metadata
logger.debug("extracted \(calls.count) tool calls")
```

### After

```swift
public enum PipelineLogLevel: Sendable { case trace, debug, info, notice, warning, error, critical }

switch level {
case .trace:    logger.trace("\(message)")
case .debug:    logger.debug("\(message)")
case .info:     logger.info("\(message)")
case .notice:   logger.notice("\(message)")
case .warning:  logger.warning("\(message)")
case .error:    logger.error("\(message)")
case .critical: logger.critical("\(message)")
}

logger.debug("extracted tool calls",
             metadata: ["conversationID": "\(conversationID)",
                        "turnIndex": "\(turnIndex)",
                        "count": "\(calls.count)"])
```

Add metadata at correlation points: chat stages → `conversationID`, `turnIndex`; tool
routing/extraction → `toolName`, `toolCallID`; provider/retry → `provider`, `model`, `attempt`.

## YAK-37 invariant

Metadata values are ids / counts / hashes only — never raw payloads, prompt text, tool
arguments, or secrets. Reuse the YAK-37 redaction/hash helper where a fingerprint is needed.

## Tests

- `PipelineLogLevel` → `Logger.Level` mapping is exhaustive; `withLogger` preserves info/warning.
- A representative pipeline run emits records carrying expected `conversationID`/`turnIndex`.
- Redaction holds: emitted metadata contains no raw payloads/secrets (assert on known-sensitive input).

## Acceptance criteria

- Pipeline logging preserves level fidelity (info/notice/warning no longer collapse to debug/error).
- Key chat/tool/provider records carry correlation metadata, filterable in Console.app.
- All added metadata is YAK-37-safe.
- PositronicKit `make verify` green; any `PipelineLogLevel` consumers in Monad/Shuttle updated.
