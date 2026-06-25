# YAK-10 — Decide swift-json-schema resolution + document the macro-trust gate

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** review of commit `23c0858` ("rely on transitive swift-json-schema")

## Problem

`project.yml` originally pinned `swift-json-schema` to an `exactVersion` so Yakamoz
resolved the same release PositronicKit builds against. Commit `23c0858` removed that
pin to "rely on transitive" resolution. Two distinct costs surfaced from this:

1. **Version drift risk.** Earlier in development, Yakamoz independently floated
   `swift-json-schema` to a release incompatible with the resolved `swift-collections`,
   producing a build break *inside the dependency* (`OrderedDictionary` vs `[String:
   JSONValue]`). Transitive resolution reintroduces the possibility of that drift if
   PositronicKit's pin and Yakamoz's resolved graph ever diverge again.
2. **Macro-trust prompt.** With the pin gone, the resolved macro target's fingerprint
   changed, so the first Xcode build now fails with *"Macro 'JSONSchemaMacro' … was
   changed since a previous approval and must be enabled before it can be used"* until
   the user clicks Trust & Enable (CLI builds need `-skipMacroValidation`).

## Proposed approach

Pick one and make it deliberate + documented:
- **Option A (re-pin):** restore an `exactVersion` in `project.yml` matching
  PositronicKit's `Package.resolved`, with a comment explaining why. Removes drift risk;
  the macro-trust prompt still appears once per fingerprint change but is stable
  thereafter.
- **Option B (stay transitive):** keep the un-pinned setup but (a) document in the README
  that the first build requires approving the JSONSchema macro (or passing
  `-skipMacroValidation`), and (b) add a guard/check that flags when Yakamoz's resolved
  `swift-json-schema` version differs from PositronicKit's `Package.resolved`.

## Acceptance criteria
- A clean checkout builds with a documented, repeatable first-build step (no surprise
  macro prompt).
- The resolution strategy (pinned vs transitive) is explained in `project.yml` and/or
  the README.
- If transitive: a check exists that catches a future version mismatch with PositronicKit.

## Pointers
- `project.yml` (`packages:` block; the pin was removed in `23c0858`)
- `../PositronicKit/Package.resolved` (the version to match)
- `README.md` (build prerequisites)
