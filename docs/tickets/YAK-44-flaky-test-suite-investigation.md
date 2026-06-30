# YAK-44 - [FLAKY] Yakamoz `make verify` intermittently fails 2 tests under load

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** YAK-33 implementation — two consecutive `make verify` runs disagreed.

## Problem

The Yakamoz test suite is non-deterministic: back-to-back `make verify` runs over the
**same** working tree produced different results.

- Run 1: `Test run with 229 tests in 27 suites failed after 70.940 seconds with 2 issues.`
- Run 2 (clean re-run, no source change): `Test run with 229 tests in 27 suites passed after 68.607 seconds.` → `** TEST SUCCEEDED **`

Both runs included the new `ToolWorkspaceSecurity` suite, which **passed in both** — so the
flake is in pre-existing tests, not YAK-33's change. Run 1 happened while another build/agent
was active on the machine, so the working hypothesis is **timing-sensitive e2e tests that
poll on wall-clock deadlines and miss under CPU contention**.

This matters because `make verify` is the CI gate (YAK-11). A flaky gate erodes trust, masks
real regressions, and forces re-runs.

## What we don't know yet

**Which 2 tests failed was not captured** — the run-1 output was piped through `tail -25`,
so only the summary line survived; the per-test failure detail scrolled off. First step is
to reproduce and capture the failing test names.

## Investigation steps

1. **Reproduce + capture.** Run the full suite to a file without truncation, repeatedly,
   under artificial load:
   ```bash
   cd Yakamoz
   for i in $(seq 1 20); do
     make verify > "verify-run-$i.log" 2>&1; echo "run $i exit=$?"
   done
   # then: grep -lE "recorded an issue|✘|failed after" verify-run-*.log
   #       grep -E "recorded an issue" <failing-log>   # extract test names + file:line
   ```
   Optionally add background load (`yes > /dev/null &` ×N cores) to bias toward the flake.
2. **Identify the pattern.** Group the failing tests. Expect them to share a trait: a
   `Task.sleep` / polling `waitUntil(timeout:)` helper, an `isSending` / transcript-completion
   spin-wait, a `UserDefaults(suiteName:)` race, or a shared in-memory `ModelContainer`.
   Several e2e view-model tests (incl. the new `ToolWorkspaceSecurityTests.waitUntil`) use a
   fixed 5s wall-clock deadline — a prime suspect.
3. **Fix the root cause, don't just bump timeouts.** Prefer event-driven waiting
   (await the actual completion signal / `AsyncStream` event) over deadline polling. If a
   shared resource races, isolate per-test (unique suite names already done in some tests —
   audit the rest). Only raise a timeout as a last resort, with a comment explaining why.
4. **Guard against regression.** Re-run the 20× loop after the fix; require 20/20 green.

## Affected code (starting points)

- `Tests/YakamozTests/ToolWorkspaceSecurityTests.swift` — `waitUntil(timeout: 5)` polling helper (representative pattern; likely shared/duplicated across e2e tests).
- Any `Tests/YakamozTests/**` test that spins on `viewModel.isSending` / transcript completion with a wall-clock deadline.
- `Tests/YakamozTests/**` tests sharing a `ModelContainer` or `UserDefaults` suite.

## Tests

- After the fix, `make verify` passes **20 consecutive runs**, including under induced CPU load.
- No test relies on a bare wall-clock `Task.sleep`/deadline as its only synchronization where
  an explicit completion signal is available.

## Acceptance criteria

- The two intermittently-failing tests are identified and named in this ticket.
- Their non-determinism is root-caused (not papered over with larger timeouts).
- `make verify` is deterministically green across repeated runs.
