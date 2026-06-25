# Yakamoz — Handoff Tickets

Open follow-ups surfaced while implementing the v1 plan
(`docs/superpowers/plans/2026-06-22-yakamoz-implementation.md`). All 11 plan
tasks are complete and committed; these are the known gaps, deferrals, and
review items left for the next person.

| ID | Title | Repo(s) | Priority | Status |
|----|-------|---------|----------|--------|
| [YAK-1](YAK-1-structured-output-seam.md) | Provider-enforced structured output (run() response-format seam) | PositronicKit + Yakamoz | High | Done |
| [YAK-2](YAK-2-persisted-turn-index-semantics.md) | Verify persisted-turn-index vs view-model turn selection | Yakamoz | High | Done |
| [YAK-3](YAK-3-workspace-tools-mid-conversation.md) | Re-wire tools when a workspace is attached mid-conversation | Yakamoz | Medium | Done |
| [YAK-4](YAK-4-facade-store-consistency.md) | Land facade store-consistency refactor (Monad double memory store) | PositronicKit + Monad | Medium | Done |
| [YAK-5](YAK-5-phase-2-embeddings-pipelines.md) | Phase 2: embeddings cluster + pipeline customization | Yakamoz + PositronicKit | Medium | Delayed |
| [YAK-6](YAK-6-persistence-tech-debt.md) | Persistence tech-debt cleanup | Yakamoz | Low | Done |
| [YAK-7](YAK-7-swiftdata-default-storage-location.md) | Make SwiftData's storage location explicit | Yakamoz | Low | Done |
| [YAK-8](YAK-8-tool-skills-toggle-ui.md) | UI to show/toggle available tools ("skills") | Yakamoz | Medium | Done |
| [YAK-9](YAK-9-inspector-side-panel.md) | Move the Inspector from a bottom drawer to a side panel | Yakamoz | Medium | Done |
| [YAK-10](YAK-10-json-schema-pin-and-macro-trust.md) | Decide swift-json-schema resolution + document macro-trust gate | Yakamoz | Medium | Open |
| [YAK-11](YAK-11-ci-test-gate.md) | Add an automated build + test gate (CI) | Yakamoz | Medium | Open |
| [YAK-12](YAK-12-run-overload-footgun.md) | Make the run() structured-output overload hard to drop silently | PositronicKit + Yakamoz | Low | Open |

Status legend: Open / Delayed / In progress / Done. Each ticket also carries its
own **Status** line.

**Next batch (open):** YAK-10, YAK-11, YAK-12 — a "harden the build & catch silent
regressions" cluster surfaced by the YAK-1 regression review. **Delayed:** YAK-5
(phase 2). Everything else is Done.
