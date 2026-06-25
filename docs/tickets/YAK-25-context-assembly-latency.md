# YAK-25 — Context assembly makes a slow LLM call on every send

- **Status:** Done
- **Priority:** Medium
- **Repos:** PositronicKit (+ Yakamoz observation)
- **Surfaced by:** YAK-23 diagnosis logs (2026-06-25)

## Problem

Every send shows a multi-second `ContextAssemblyStage: Context gathered in Ns` delay
(observed 2–9.7s), even on an empty conversation with `0 memories selected`. The YAK-23
trace revealed why: the context stage issues its **own OpenRouter LLM call** before the
actual chat turn — the diagnostic log shows an `OpenRouter stream complete … toolsAdvertised=0`
completion that finishes right as `Context gathered` is logged, separate from the real
turn's `toolsAdvertised=8` call. So each user message pays for two sequential provider
round-trips, and the first (context) one dominates the latency.

## Task

- Identify what the context-assembly stage calls the LLM for (query expansion?
  summarization? relevance?) and whether it should run at all when there is nothing to
  retrieve (`0 semantic + 0 tag matches`, empty memory/vector store).
- Short-circuit the LLM call when the conversation/memory set is empty or below a
  threshold, so a fresh conversation goes straight to the turn with no extra round-trip.
- Consider making the context LLM call use a cheaper/faster model or running it
  concurrently with prompt assembly where possible.

## Acceptance criteria
- A send on an empty conversation issues no extra context-stage LLM round-trip (or a
  negligible one); `Context gathered` time drops to sub-second in that case.
- Retrieval behavior for non-empty memory/context is unchanged.
- `make verify` green in PositronicKit; Monad/Shuttle build.

## Pointers
- `../PositronicKit/Sources/PositronicKit/...` ContextAssemblyStage / MemoryRetrievalStage / ContextManager
- Yakamoz wires `sectionProviders: [CurrentTimeSectionProvider()]` and a no-op embedding service by default — confirm whether the context LLM call is even desired in Yakamoz's configuration.

## Resolution

- The extra provider call was not in `ContextAssemblyStage`; it was in
  `MemoryRetrievalStage`, which generated tags via the LLM before checking whether any
  memory corpus existed to search.
- Added a `MemoryStoreProtocol.hasAnyMemory()` preflight and short-circuited memory
  retrieval before tag generation and embedding when the store is empty.
- Preserved non-empty retrieval behavior, including injected/mock memory stores with
  semantic search results.

## Verification

- `swift test --filter ContextManagerTests` in PositronicKit
- `swift test --filter MemoryStoreWiringTests` in PositronicKit
- `make verify` in PositronicKit
- `swift build` in Monad
- `swift build` in Shuttle
