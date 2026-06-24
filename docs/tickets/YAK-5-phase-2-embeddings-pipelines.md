# YAK-5 — Phase 2: embeddings cluster + pipeline customization

- **Status:** Delayed (explicitly deprioritized; revisit later)
- **Priority:** Medium
- **Repos:** Yakamoz (+ possibly PositronicKit for API embeddings)
- **Surfaced by:** design spec §7 / §2 (explicitly deferred from v1)

## Scope

v1 deliberately excluded the embeddings-dependent cluster and pipeline customization
(see `docs/superpowers/specs/2026-06-22-yakamoz-design.md` §7). They share an
embeddings dependency, so build them together as one coherent phase 2.

### A. Embeddings cluster
- **Context Inspector (#4):** `ContextManager` / `ContextRanker` — show which context
  items were selected for a turn and their cosine/tag/time-decay scores. Add a
  Context tab to the inspector drawer.
- **Memory:** `MemoryStoreProtocol` — persistent retrieved facts feeding context;
  surface in `ChatMetadata.memories`.
- **Vector store:** `VectorStoreProtocol`, SwiftData-backed.
- **Semantic search lab (#7):** search a small corpus, show similarity ranking.

`ContextRanker` is genuinely embedding-based (cosine on embedding vectors), so this
needs real embeddings. MiniLM is out of scope — implement an
`EmbeddingServiceProtocol` over the same OpenAI-compatible base URL
(`text-embedding-3-small` / Ollama `nomic-embed-text`). Requires an
embeddings-capable endpoint + one extra API call per context build; add an
endpoint-capability check.

### B. Pipeline customization
- `Pipeline` / `PipelineStage` / `PipelineBuilder` — the `contextPipeline` and
  `assemblyPipeline` override seams on `run(...)`. Add a stage-event visualizer
  (the most abstract primitive; lowest priority).

## Acceptance criteria
- A Context tab shows real per-turn ranking scores against a seeded memory/context set.
- A semantic-search view returns ranked results, no live model required in tests
  (use a deterministic fake embedding service).
- Pipeline override + visualizer behind an opt-in.

## Pointers
- `docs/superpowers/specs/2026-06-22-yakamoz-design.md` §7 (deferred catalog)
- PositronicKit: `EmbeddingServiceProtocol`, `VectorStoreProtocol`, `ContextManager`/`ContextRanker`, `MemoryStoreProtocol`, `Pipeline`/`PipelineStage`
