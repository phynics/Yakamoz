# YAK-36 - [BUG] Local embedding APIs allocate attacker-sized batches

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

The local embedding path validates arithmetic safety, but it does not enforce policy
limits on input size. `PKFastEmbed.embed(_ texts:)` allocates output for every submitted
text and the Rust bridge decodes all text into memory before inference.

Yakamoz's future embeddings/context features should not be able to feed unbounded user
documents, notes, or workspace contents into local embedding generation.

## Affected code

- `../PositronicKit/Sources/PKFastEmbed/PKFastEmbed.swift:133`
- `../PositronicKit/native/pkfastembed/src/lib.rs:343`
- `../PositronicKit/Sources/PKLocalEmbeddings/LocalEmbeddingService.swift`
- Yakamoz context/embedding ingestion paths when YAK-5 resumes

## Before / after

### Before

```swift
let totalCount = try Self.checkedOutputCount(dimensions: dimensions, textCount: texts.count)
var output = [Float](repeating: 0, count: totalCount)
```

### After

```swift
try EmbeddingInputBudget.default.validate(texts)

let totalCount = try Self.checkedOutputCount(dimensions: dimensions, textCount: texts.count)
var output = [Float](repeating: 0, count: totalCount)
```

The budget should cover text count, per-text bytes/tokens, total bytes, and cancellation
or chunking behavior.

## Tests

- Over-limit batch count fails before allocation.
- Over-limit text size fails before FFI/native inference.
- Natural Language and MiniLM backends enforce the same public budget contract.
- Yakamoz ingestion/context paths chunk or reject over-limit content before calling embeddings.

## Acceptance criteria

- Embedding APIs have documented maximum batch and text sizes.
- Limit failures return typed, user-friendly errors.
- Yakamoz's future embeddings pipeline has a clear ingestion budget before enabling YAK-5 work.
- PositronicKit verification and Yakamoz `make verify` are green.
