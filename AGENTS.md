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
