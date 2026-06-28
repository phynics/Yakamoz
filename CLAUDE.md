# CLAUDE.md — Yakamoz

Yakamoz-specific workflow only. Workspace-wide rules (repo ownership, per-subproject
build commands, shared conventions): [../CLAUDE.md](../CLAUDE.md). Product, feature, and
architecture detail: [README.md](README.md). `AGENTS.md` is identical to this file.

Local, non-sandboxed, single-user macOS SwiftUI showcase app driving `PositronicKit`.
No server/client — all workspaces are local.

## Build notes

Commands are in [../CLAUDE.md](../CLAUDE.md) ("Commands"). Gotchas: run `make generate`
after editing `project.yml`; trust `make verify` (a bare `swift test` can pass having run
**0** tests); if a build fails with `missing Metal Toolchain`, run
`xcodebuild -downloadComponent MetalToolchain` once.

## Boundaries

App target (`Sources/Yakamoz`) imports only SwiftUI/SwiftData/`YakamozCore`, never a
`PositronicKit`/`PKShared` type (README "Architecture boundary"). Put reusable logic in
`YakamozCore` or upstream in `PositronicKit`, not the app. Match a file's existing test
framework; don't mix within a file.

## Workflow: plan → ticket → review → ticket → …

A loop, not a line:

- **Plan** — spec + ticket-by-ticket plan in [`docs/superpowers/`](docs/superpowers/); read
  before implementing.
- **Ticket** — decompose into tickets in [`docs/tickets/`](docs/tickets/); implement.
- **Review** — review the landed merge (correctness first), **capturing findings as tickets**
  rather than only reporting inline.
- **Repeat** — review tickets are the next implementation round.

All tickets live in `docs/tickets/` — one file `YAK-<id>-<slug>.md`, each with a `Status`
line and (problem / affected `file:line` / before-after code / tests / acceptance criteria).
Numeric `YAK-N` for the backlog; a lettered batch (e.g. `YAK-TF*`) for a cohesive review set.
**Update the index** [`docs/tickets/README.md`](docs/tickets/README.md) in the same change
(table row + Open/Delayed summary; tag titles `[BUG]`/`[SECURITY]`).

### Executing a ticket

TDD throughout (red → green → refactor). On completion: flip the ticket `Status` to `Done`
with a short resolution note, update the index in the same change, and run `make verify`
(must be green; trust it over bare `swift test`). Pick one execution mode:

- **Inline** — implement on the current branch; **commit per ticket at the end**. Before
  committing, `git status` and **warn about any unrelated uncommitted files**; stage only the
  ticket's own files, never blanket `git add -A`.
- **Multi-agent worktrees** — dispatch each independent ticket to a subagent in its own git
  worktree (commits land in the worktree); the originating thread stays out of implementation
  and only **reviews and merges** completed worktrees back. Use for batches of independent
  tickets; see `superpowers:using-git-worktrees` and `superpowers:dispatching-parallel-agents`.

Commit/push only when asked.
