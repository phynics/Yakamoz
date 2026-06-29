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
| [YAK-13](YAK-13-bundle-identifier-rename.md) | Rename bundle identifier to me.atkn.Yakamoz | Yakamoz | Medium | Done |
| [YAK-14](YAK-14-userdefaults-secret-storage.md) | Replace Keychain secret storage with UserDefaults | Yakamoz | Medium | Done |
| [YAK-15](YAK-15-inspector-selection-not-reacting.md) | [BUG] Inspector doesn't react to message selection until a later turn | Yakamoz | High | Done |
| [YAK-16](YAK-16-journal-tab-all-volatile.md) | [BUG] Journal tab marks everything volatile / no updates | Yakamoz + PositronicKit | Medium | Done |
| [YAK-17](YAK-17-inspector-workspace-tab-cleanup.md) | Inspector Workspace tab: drop file list, add detach | Yakamoz | Medium | Done |
| [YAK-18](YAK-18-inspector-tools-grouped-by-workspace.md) | Inspector Tools tab: group by workspace vs built-in | Yakamoz | Low | Done |
| [YAK-19](YAK-19-tool-calls-not-working.md) | [BUG] Tool calls not working; no streaming UI indicator | Yakamoz + PositronicKit | High | Done |
| [YAK-20](YAK-20-selection-indicator-too-strong.md) | Turn-selection indicator overpowers message bubbles | Yakamoz | Low | Done |
| [YAK-21](YAK-21-new-conversation-list-jump.md) | [BUG] Creating a conversation causes a list jump/reorder | Yakamoz | Medium | Done |
| [YAK-22](YAK-22-settings-ux-polish.md) | Settings UX polish | Yakamoz | Low | Open |
| [YAK-23](YAK-23-tool-followup-turn-hangs.md) | [BUG] Streamed tool calls dropped via OpenRouter (SSE decoder ignored snake_case) — FIXED | Yakamoz + PositronicKit | High | Done |
| [YAK-24](YAK-24-surface-empty-model-response.md) | Surface empty model responses instead of a silent blank bubble | Yakamoz | High | Done |
| [YAK-25](YAK-25-context-assembly-latency.md) | Context assembly makes a slow LLM call on every send | PositronicKit | Medium | Done |
| [YAK-26](YAK-26-tool-call-id-coercion-breaks-history.md) | [BUG] Tool-call id coerced to random UUID breaks a conversation's next turn (HTTP 400) | PositronicKit | High | Done |
| [YAK-27](YAK-27-markdown-visualizer.md) | Integrate a Markdown visualizer for assistant responses | Yakamoz | Medium | Done |
| [YAK-28](YAK-28-quick-model-switching.md) | Quick model switching with favorites and recency | Yakamoz + PositronicKit | Medium | Done |
| [YAK-29](YAK-29-timeline-state-dots.md) | Timeline state dots in the chat list | Yakamoz + PositronicKit | Medium | Done |
| [YAK-30](YAK-30-terminal-workspace-entrypoints.md) | Terminal workspace entrypoints | Yakamoz | Medium | Open |
| [YAK-31](YAK-31-permissioned-tools-approval-gate.md) | [SECURITY] Permissioned tools execute without an approval gate | PositronicKit + Yakamoz | High | Open |
| [YAK-32](YAK-32-agent-workspace-seed-path-traversal.md) | [SECURITY] Agent workspace seed filenames can escape `Notes` | PositronicKit + Yakamoz | Medium | Open |
| [YAK-33](YAK-33-explicit-workspaceid-fallback.md) | [SECURITY] Invalid explicit `workspaceID` falls back to another workspace | PositronicKit + Yakamoz | Medium | Open |
| [YAK-34](YAK-34-external-tool-output-forgery.md) | [SECURITY] External tool outputs can be forged into timeline history | PositronicKit + Yakamoz | Medium | Open |
| [YAK-35](YAK-35-filesystem-search-resource-limits.md) | [BUG] Filesystem search tools lack producer-side resource limits | PositronicKit + Yakamoz | Medium | Open |
| [YAK-36](YAK-36-local-embedding-resource-limits.md) | [BUG] Local embedding APIs allocate attacker-sized batches | PositronicKit + Yakamoz | Medium | Open |
| [YAK-37](YAK-37-provider-tool-log-redaction.md) | [SECURITY] Provider and tool debug logs can capture raw sensitive payloads | PositronicKit + Yakamoz | Low | Open |
| [YAK-38](YAK-38-pktestsupport-mock-workspace-sanitizer.md) | [BUG] Exported `MockLocalWorkspace` omits path containment checks | PositronicKit + Yakamoz | Low | Open |
| [YAK-39](YAK-39-context-role-and-tool-fallback-hardening.md) | [SECURITY] Follow up prompt-context role elevation and text tool fallback | PositronicKit + Yakamoz | Medium | Open |

## Terminal-workspace post-merge review (YAK-TF series)

Findings from the integration review of merge `78a7b7f`
(`feature/terminal-workspace`, YAK-T1..T5 — spec/plan in
`docs/superpowers/{specs,plans}/2026-06-26-terminal-workspace*`). Separate `TF`
("terminal fix") id series so they read as a cohesive batch. TF1–TF6 done.

| ID | Title | Repo(s) | Priority | Status |
|----|-------|---------|----------|--------|
| [YAK-TF1](YAK-TF1-send-input-approval-bypass.md) | [SECURITY] `terminal_send_input` bypasses the per-command approval gate (un-gated arbitrary exec) | Yakamoz | **Critical** | Done |
| [YAK-TF2](YAK-TF2-registry-double-spawn-race.md) | [BUG] Registry `session(for:)` check-then-act across `await` → duplicate shells + leaked PTY | Yakamoz | Medium | Done |
| [YAK-TF3](YAK-TF3-partial-output-duplication.md) | [BUG] Partial output re-emitted by `read`/`wait` after a `.running` `run` | Yakamoz | Medium | Done |
| [YAK-TF4](YAK-TF4-unbounded-buffer-growth.md) | `TerminalSession.buffer` grows without bound (design called for a ring-buffer) | Yakamoz | Medium | Done |
| [YAK-TF5](YAK-TF5-approval-banner-conversation-scoping.md) | Approval banner is app-global; can show/approve another conversation's command | Yakamoz | Low | Done |
| [YAK-TF6](YAK-TF6-minor-cleanup.md) | Cleanup: orphan `WorkspaceModel` on detach; fire-and-forget quit teardown; dead `.notRunning` | Yakamoz | Low | Done |

Suggested order: **TF1 first** (security blocker; also makes `.notRunning` in TF6c
reachable — now done), then TF2/TF3 (lifecycle + output correctness), then TF4/TF5/TF6.

Status legend: Open / Delayed / In progress / Done. Each ticket also carries its
own **Status** line.

**Open:** YAK-31 (High — permissioned tool approval gate), YAK-30 (Medium — terminal workspace entrypoints), YAK-32 (Medium — agent workspace seed path traversal), YAK-33 (Medium — explicit workspaceID fallback), YAK-34 (Medium — external tool-output forgery), YAK-35 (Medium — filesystem search resource limits), YAK-36 (Medium — local embedding resource limits), YAK-39 (Medium — context-role and fallback hardening), YAK-22 (Low — settings polish, needs design direction), YAK-37 (Low — provider/tool log redaction), YAK-38 (Low — PKTestSupport mock workspace containment).
**Delayed:** YAK-5 (phase 2). Note
(YAK-23, FIXED): streamed tool calls were dropped for every
model via OpenRouter because the SSE decoder ignored snake_case (`tool_calls`/`finish_reason`);
fixed with a convertFromSnakeCase decoder.
