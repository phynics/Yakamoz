# Workflow

Work is tracked as GitHub issues on
[`phynics/Yakamoz`](https://github.com/phynics/Yakamoz/issues). There is no local ticket
directory. The tracker loop is **issue → implement → review → issue → …** — a loop, not a
line. This file is the detailed reference; [AGENTS.md](../AGENTS.md) carries the summary.

## Anatomy of an issue

Every issue is agent-ready before implementation starts. Required sections:

- **Context** — the problem and the affected area (`file:line`, view, command).
- **Acceptance criteria** — the observable end state, as a checklist.
- **Verification** — how acceptance is proven: usually `make verify`, plus any manual check.

Optional: **Out of scope** — adjacent work deliberately excluded, so the change stays scoped.

Use GitHub's default labels only (`bug`, `enhancement`, `documentation`). No custom label
taxonomy, no status lines — GitHub already tracks open/closed.

## The loop

- **Plan** — write the spec into the issue (or a repo doc, linked from the issue) before
  implementing. An issue without acceptance criteria is not ready.
- **Implement** — one issue at a time; keep the change scoped to the issue. TDD throughout:
  red → green → refactor.
- **Verify** — `make verify` is required for any change touching `Sources/`, `Tests/`, or
  `project.yml`; it must be green (trust it over bare `swift test`). Docs-only changes are
  gated by CI on push; run `make verify` locally only when you want the evidence.
- **Review** — review the landed change with fresh context, correctness first. Every finding
  becomes a new issue **unless** it is fixed in the same change, in which case it is noted in
  the resolution comment.
- **Close** — comment a resolution note, then close. Review issues are the next implementation
  round.

## Resolution note

The close comment states what landed, where (`file:line` or commit), and the verification
evidence (`make verify: executed N tests`, or the manual check performed). Keep it short.

## Executing an issue

Implement on the current branch (normally `main`); branch only for parallel or experimental
work. Commit per issue at the end:

- Before committing, run `git status` and **warn about any unrelated uncommitted files**.
- Stage only the issue's own files, never `git add -A`.
- Commit subjects follow the repository's Conventional Commits style
  (`type(scope): summary`); cite the issue as `Refs #N` in the body, not the subject.
- Commit and push only when asked.

## Tracker hygiene

- Reference work as GitHub `#N` links or self-contained prose. Never introduce IDs from the
  retired local ticket system.
- Dead `YAK-*`/`SID-*` references found while editing a file are stripped in that change; do
  not sweep them repo-wide.

## Vocabulary and decisions

- [`CONTEXT.md`](../CONTEXT.md) — the domain glossary. Yakamoz-owned terms only;
  PositronicKit owns its own vocabulary.
- [`docs/adr/`](adr/) — one-paragraph decisions that are hard to reverse, surprising without
  context, and the result of a real trade-off. Most changes do not need one.
