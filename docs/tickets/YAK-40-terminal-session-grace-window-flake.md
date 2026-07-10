# YAK-40 — Terminal session grace-window flake breaks verify

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** YAK-30 verification pass (2026-06-29)

## Problem

`make verify` is currently not a reliable merge gate because `TerminalSessionTests`
contains a timing-sensitive failure:

- failing suite: `TerminalSessionTests`
- failing test: `completedCommandsDoNotGrowRetainedBufferWithoutBound()`
- observed failure:
  - sometimes `TerminalSession.run("echo ...", graceMs: 4000)` returns
    `.running("2-xxxxxxxx...")`
  - the test expects `.finished(output, 0)` for every iteration

The failure reproduces on both the YAK-30 worktree and `main`, so it appears in the
existing terminal-session behavior rather than the workspace-entrypoint changes. The
YAK-30 focused regression suite passed, but the branch cannot be merged cleanly while
`make verify` remains red.

## Reproduction

```bash
make test TEST_FILTER=TerminalSessionTests
```

Observed during reproduction:

- `completedCommandsDoNotGrowRetainedBufferWithoutBound()` intermittently fails with:
  - `expected finished, got .running("2-xxxxxxxx...")`
  - `expected finished, got .running("")`

It also reproduces on `main` with the same focused command:

```bash
make test TEST_FILTER=TerminalSessionTests
```

Observed on `main`:

- `TerminalSessionTests.completedCommandsDoNotGrowRetainedBufferWithoutBound()`
  fails at `TerminalSessionTests.swift:184`
- latest failure text:
  - `expected finished, got .running("")`

The full gate also fails:

```bash
make verify
```

## Likely seam

The flaky behavior is at the interaction between:

- `Tests/YakamozTests/TerminalSessionTests.swift:173`
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift`

Specifically:

- the test assumes `graceMs: 4000` is sufficient for forty short `echo` commands to
  settle as `.finished`
- the runtime sometimes still reports `.running`, which suggests either:
  - the grace-window contract is too strict for the current implementation, or
  - the test is asserting synchronously on a behavior that is intentionally best-effort

## Task

- Reproduce the failure in isolation and determine whether the contract should be:
  - "short commands must finish within the grace window", or
  - "tests must tolerate `.running` then finalize via `wait`"
- Compare `completedCommandsDoNotGrowRetainedBufferWithoutBound()` with the other
  terminal-session tests that already accept `.running` for long-lived commands.
- Land either:
  - a production fix that makes short completed commands reliably resolve as `.finished`,
    or
  - a test fix that preserves the buffer-retention assertion without assuming eager
    completion beyond the documented contract.
- Re-run:
  - `make test TEST_FILTER=TerminalSessionTests`
  - `make verify`

## Pointers

- `Tests/YakamozTests/TerminalSessionTests.swift`
- `Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift`
- `docs/tickets/YAK-TF3-partial-output-duplication.md`
