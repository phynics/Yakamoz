# CLAUDE.md — Yakamoz

Yakamoz is a standalone repository. Product, feature, and architecture detail:
[README.md](README.md). `AGENTS.md` is identical to this file.

Local, non-sandboxed, single-user macOS SwiftUI showcase app driving `PositronicKit`.
No server/client — all workspaces are local.

## Build notes

All commands run from this directory and go through the [`Makefile`](Makefile), which wraps
`xcodegen` + `xcodebuild` with a project-local `DerivedData`/`SourcePackages` path:

```bash
make generate   # regenerate Yakamoz.xcodeproj from project.yml
make build      # generate + build the app
make test       # generate + run the full test suite (macOS destination)
make verify     # generate + headless xcodebuild test, failing if zero tests execute

make test TEST_FILTER=InspectableChatIntegrationTests   # single suite/class
```

Gotchas: run `make generate` after editing `project.yml`; trust `make verify` (a bare
`swift test` can pass having run **0** tests); if a build fails with `missing Metal
Toolchain`, run `xcodebuild -downloadComponent MetalToolchain` once.

## Boundaries

App target (`Sources/Yakamoz`) imports only SwiftUI/SwiftData/`YakamozCore`, never a
`PositronicKit` type (README "Architecture boundary"). Put reusable logic in `YakamozCore`
or upstream in `PositronicKit`, not the app. Match a file's existing test framework; don't
mix within a file.

Dependencies resolve from released versions: `PositronicKit` is pinned in `project.yml` to
an exact semver (`exactVersion`), never a local path. To develop against an unreleased
PositronicKit change, use an Xcode local package override in your working copy only; do not
commit a path dependency.

## Workflow: issue → implement → review → issue → …

A loop, not a line. Work is tracked as GitHub issues on
[`phynics/Yakamoz`](https://github.com/phynics/Yakamoz/issues) — there is no local ticket
directory.

- **Plan** — discuss in an issue; write the spec/plan into the issue (or a repo doc)
  before implementing.
- **Implement** — one issue at a time; keep the change scoped to the issue.
- **Review** — review the landed change (correctness first), **capturing findings as new
  issues** rather than only reporting inline.
- **Repeat** — review issues are the next implementation round.

### Executing an issue

TDD throughout (red → green → refactor). On completion, run `make verify` (must be green;
trust it over bare `swift test`), then close the issue with a short resolution note.
Implement on the current branch and commit per issue at the end; before committing,
`git status` and **warn about any unrelated uncommitted files**; stage only the issue's own
files, never blanket `git add -A`.

Commit/push only when asked.
