# AGENTS.md — Yakamoz

Yakamoz is a standalone repository. Product, feature, and architecture detail:
[README.md](README.md).

Local, non-sandboxed, single-user macOS SwiftUI showcase app driving `PositronicKit`.
No server — local workspaces live on disk; the optional Gnostic client (`YakamozNetwork`)
only browses a remote network and persists nothing locally (ADR 0002).

## Build notes

All commands run from this directory and go through the [`Makefile`](Makefile), which wraps
`xcodegen` + `xcodebuild` with a project-local `DerivedData`/`SourcePackages` path:

```bash
make generate   # regenerate Yakamoz.xcodeproj from project.yml
make build      # generate + build the app
make test       # generate + run the full test suite (macOS destination)
make verify     # generate + headless xcodebuild test, failing if zero tests execute

make test TEST_FILTER=InspectableChatIntegrationTests   # single suite/class, either bundle
make gnostic-smoke    # opt-in real Mosquitto + Gnostic Node smoke test
```

`TEST_FILTER` matches a suite/class name in **either** test bundle; `make test` fails when the
filter matches nothing (xcodebuild exits 0 after running zero tests).

Gotchas: run `make generate` after editing `project.yml`; trust `make verify` (a bare
`swift test` can pass having run **0** tests); if a build fails with `missing Metal
Toolchain`, run `xcodebuild -downloadComponent MetalToolchain` once.

The opt-in `make gnostic-smoke` target is excluded from `make verify` and CI. It uses
`GNOSTIC_CONFIG` (default `~/.gnostic/config.json`), starts a temporary `gnostic serve`
process, and expects Mosquitto on `127.0.0.1:1883`. If Mosquitto is not on `PATH`, the
target runs its broker probe through `nix-shell -p mosquitto`. Override `YAKAMOZ_GNOSTIC_HOST`,
`YAKAMOZ_GNOSTIC_PORT`, `YAKAMOZ_GNOSTIC_NAMESPACE`, and `YAKAMOZ_SMOKE_TOOL_ID` when
needed. The configured Node must advertise at least one Timeline and Workspace.

## Boundaries

App target (`Sources/Yakamoz`) imports only SwiftUI/SwiftData/`YakamozCore`/`YakamozNetwork`,
never a `PositronicKit` or `GnosticCore` type (README "Architecture boundary"). The Gnostic
client lives in `YakamozNetwork`, which depends on `YakamozCore` one-way;
`Sources/YakamozNetwork/Transport/GnosticCoreTransport.swift` is the only file under
`Sources/` that imports `GnosticCore` (its mapping test is the one exception, and it is
offline). Put reusable logic in `YakamozCore`/`YakamozNetwork` or upstream in
`PositronicKit`, not the app. Match a file's existing test framework; don't mix within a
file.

Dependencies resolve from released versions: `PositronicKit` is pinned in `project.yml` to
an exact semver (`exactVersion`), never a local path. To develop against an unreleased
PositronicKit change, use an Xcode local package override in your working copy only; do not
commit a path dependency. `Gnostic` follows the same rule and is pinned to `0.4.2`, which
is built against the same `PositronicKit` version Yakamoz pins; moving either pin requires
moving the other in the same commit, because SwiftPM admits exactly one exact pin per
package.

## Workflow

Work is tracked as GitHub issues on
[`phynics/Yakamoz`](https://github.com/phynics/Yakamoz/issues); there is no local ticket
directory. The loop is **issue → implement → review → issue → …**.

- **Plan** — put the spec (context, acceptance criteria, verification) in the issue before
  implementing.
- **Implement** — one issue at a time, scoped to the issue; TDD red → green → refactor.
- **Verify** — `make verify` for changes touching `Sources/`, `Tests/`, or `project.yml`;
  CI gates docs-only changes.
- **Review** — fresh context, correctness first; findings become issues unless fixed in the
  same change.
- **Close** — resolution note with verification evidence, then close.

Commit per issue at the end; before committing, run `git status` and warn about unrelated
uncommitted files; stage only the issue's files, never `git add -A`; cite `Refs #N` in the
commit body. Commit and push only when asked.

Full detail: [docs/workflow.md](docs/workflow.md). Vocabulary: [CONTEXT.md](CONTEXT.md).
Decisions: [docs/adr/](docs/adr/).
