# YAK-12 — Make the `run()` structured-output overload hard to drop silently

- **Status:** Open
- **Priority:** Low
- **Repos:** PositronicKit (root cause) + Yakamoz (consumer)
- **Surfaced by:** root-cause analysis of the YAK-1 regression (`23c0858`)

## Problem

`PositronicKit` exposes two `run(...)` overloads: a full one taking
`structuredOutput: StructuredOutputRequest?`, and a convenience one **without** that
parameter that delegates to the full one passing `structuredOutput: nil`. Because both
are callable with the same argument list (the full one's `structuredOutput` has a default
of `nil`), simply omitting the argument at a call site silently selects the
nil-hardcoding overload. That is exactly how the YAK-1 regression happened:
`structuredOutput:` was dropped from `YakamozRuntime`'s `kit.run(...)` calls, it still
compiled, and typed replies quietly stopped sending their schema.

This is a transport-neutral footgun in the shared runtime, so the durable fix belongs in
PositronicKit, not in each consumer.

## Proposed approach (PositronicKit)

Pick one:
- **Collapse the overloads:** delete the convenience overload and keep a single `run(...)`
  with `structuredOutput: StructuredOutputRequest? = nil`. Callers that omit it still
  work, but there's no second overload for resolution to silently fall to, so the
  behavior is unambiguous.
- **Or** keep both but make the divergence visible (e.g. `@available(*, deprecated,
  message: "pass structuredOutput: explicitly")` on the convenience overload), so a
  call that loses the argument produces a warning rather than silent behavior change.

Keep it back-compatible; update `PositronicKitExamples`, tests, and `Monad`/`Shuttle`
call sites in the same change per the cross-repo convention.

## Acceptance criteria
- Omitting `structuredOutput:` at a call site no longer silently changes behavior (either
  it's the same single function, or it warns).
- `make verify` green in PositronicKit; `Monad`/`Shuttle`/Yakamoz still build.
- A test documents the intended single-path behavior.

## Pointers
- `../PositronicKit/Sources/PositronicKit/PositronicKit.swift` (the two `run` overloads;
  the convenience one hardcodes `structuredOutput: nil`)
- Yakamoz regression guard already added: `Tests/YakamozTests/RuntimeCompositionTests.swift`
  ("run() forwards a structured-output request through to the LLM transport")
