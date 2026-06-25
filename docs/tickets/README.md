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
| [YAK-10](YAK-10-json-schema-pin-and-macro-trust.md) | Decide swift-json-schema resolution + document macro-trust gate | Yakamoz | Medium | Done |
| [YAK-11](YAK-11-ci-test-gate.md) | Add an automated build + test gate (CI) | Yakamoz | Medium | Done |
| [YAK-12](YAK-12-run-overload-footgun.md) | Make the run() structured-output overload hard to drop silently | PositronicKit + Yakamoz | Low | Done |
| [YAK-13](YAK-13-bundle-identifier-rename.md) | Rename bundle identifier to me.atkn.Yakamoz | Yakamoz | Medium | Open |
| [YAK-14](YAK-14-userdefaults-secret-storage.md) | Replace Keychain secret storage with UserDefaults | Yakamoz | Medium | Open |
| [YAK-15](YAK-15-inspector-selection-not-reacting.md) | [BUG] Inspector doesn't react to message selection until a later turn | Yakamoz | High | Open |
| [YAK-16](YAK-16-journal-tab-all-volatile.md) | [BUG] Journal tab marks everything volatile / no updates | Yakamoz + PositronicKit | Medium | Open |
| [YAK-17](YAK-17-inspector-workspace-tab-cleanup.md) | Inspector Workspace tab: drop file list, add detach | Yakamoz | Medium | Open |
| [YAK-18](YAK-18-inspector-tools-grouped-by-workspace.md) | Inspector Tools tab: group by workspace vs built-in | Yakamoz | Low | Open |
| [YAK-19](YAK-19-tool-calls-not-working.md) | [BUG] Tool calls not working; no streaming UI indicator | Yakamoz + PositronicKit | High | Open |
| [YAK-20](YAK-20-selection-indicator-too-strong.md) | Turn-selection indicator overpowers message bubbles | Yakamoz | Low | Open |
| [YAK-21](YAK-21-new-conversation-list-jump.md) | [BUG] Creating a conversation causes a list jump/reorder | Yakamoz | Medium | Open |
| [YAK-22](YAK-22-settings-ux-polish.md) | Settings UX polish | Yakamoz | Low | Open |

Status legend: Open / Delayed / In progress / Done. Each ticket also carries its
own **Status** line.

**Next batch (open):** YAK-13–YAK-22, from manual-testing field feedback (2026-06-25).
Bugs first: YAK-15, YAK-19 (High); YAK-16, YAK-21 (Medium bugs). **Delayed:** YAK-5.
Everything ≤ YAK-12 is Done.
