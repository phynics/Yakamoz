# YAK-11 — Add an automated build + test gate (CI)

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** the YAK-1 regression (commit `23c0858` → fix `7931d1a`)

## Problem

A behavioral regression — `YakamozRuntime.run` silently dropping `structuredOutput:`,
disabling typed replies — **compiled cleanly and passed the entire existing test
suite**. It was caught only by a human reading the diff. There is currently no automated
gate that builds the app target and runs the test suite on every change, so a silent
regression like this can land unnoticed.

## Proposed approach

Add a single reproducible verification entry point and run it in CI:
- A `make verify` (or script) target that runs:
  `xcodegen generate` →
  `xcodebuild test -scheme Yakamoz -destination 'platform=macOS' -skipMacroValidation`
  (the `-skipMacroValidation` flag is needed in non-interactive CI; see YAK-10).
- Wire it to a CI workflow (e.g. GitHub Actions `macos-latest`) triggered on push/PR.
- Assert the executed test count is non-zero in the gate — a `swift test`/`xcodebuild`
  run can report success while executing **0 tests** (documented pitfall in this
  workspace's memory). Fail the build if the run executed zero tests.

## Acceptance criteria
- One command builds the app target and runs all tests headlessly from a clean checkout.
- CI runs it on every push/PR and blocks on failure.
- The gate fails if zero tests executed.
- Document the command in the README.

## Pointers
- `project.yml`, `Tests/YakamozTests/` (current 126-test suite)
- The regression this would have caught: `git show 23c0858 -- Sources/YakamozCore/Runtime/YakamozRuntime.swift` vs fix `7931d1a`
- Note: this repo has no remote configured yet — wiring CI may also mean pushing to a host first.
