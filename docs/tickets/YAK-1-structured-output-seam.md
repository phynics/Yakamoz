# YAK-1 — Provider-enforced structured output (run() response-format seam)

- **Status:** Open
- **Priority:** High
- **Repos:** PositronicKit (new public seam) + Yakamoz (consumer)
- **Surfaced by:** CP10 / Task 10 (typed replies)

## Problem

Yakamoz's typed-reply mode is **best-effort**, not provider-enforced. The model is
asked for JSON via the system instruction, and Yakamoz decodes the final text with
`StructuredOutputDecoder` — but nothing forces the provider to emit schema-valid
JSON, so a non-conforming reply just surfaces a decode error.

The reason: `PositronicKit.run(...)` and `GenerationParameters` expose **no
response-format / schema parameter**. The schema-aware path exists only on
`LLMServiceProtocol.chatStream(structuredOutput:)`, which `ChatEngine`'s chat loop
does not call. So a downstream app cannot push an `LLMResponseFormat` /
`StructuredOutputRequest` onto a live chat turn without modifying PositronicKit.

## Proposed approach

Add a structured-output seam to PositronicKit, mirroring how `TurnInspecting` was
added:

1. Add `structuredOutput: StructuredOutputRequest?` (or `LLMResponseFormat?`) to
   `GenerationParameters` (PKShared) **or** as a new `run(...)` parameter
   (`Sources/PositronicKit/PositronicKit.swift`).
2. Thread it through `ChatEngine` (`Services/Chat/`) so the LLM call uses
   `chatStream(structuredOutput:)` when present.
3. Keep it optional/back-compatible (default `nil`); update `PositronicKitExamples`
   + tests; keep `make verify` green; keep `Monad`/`Shuttle` compiling.

Then in Yakamoz: pass the `TypedReplyPayload` schema through `makeChatViewModel` →
`run(...)` when typed-reply is enabled, and keep the existing decode/persist path
(`Sources/YakamozCore/Agents/TypedReply.swift`, `ResponseDTO.structured*` fields,
`ResponseInspectorView`).

## Acceptance criteria

- A typed-reply conversation sends the schema to the provider; a conforming reply
  decodes; the Response tab shows schema + parsed JSON.
- New PositronicKit unit test asserting the request carries the schema.
- No breaking change for existing `run(...)` callers.

## Pointers
- `../PositronicKit/Sources/PositronicKit/PositronicKit.swift` (`run`)
- `../PositronicKit/Sources/PKShared/.../GenerationParameters` , `LLMServiceProtocol.chatStream(structuredOutput:)`
- `Sources/YakamozCore/Agents/TypedReply.swift`, `Sources/YakamozCore/Inspection/InspectionDTOs.swift` (`ResponseDTO`)
