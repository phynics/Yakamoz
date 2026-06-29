# Yakamoz Open Ticket Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the first five actionable open Yakamoz tickets after the terminal review batch: `YAK-TF5`, `YAK-TF6`, `YAK-27`, `YAK-28`, and `YAK-29`.

**Architecture:** Keep the terminal follow-ups narrowly scoped to approval/workspace cleanup seams that already exist. Land the three product tickets in increasing integration depth: render markdown at the view edge, add model switching in Settings through a runtime-backed catalog seam, then persist and surface sidebar timeline state through `ConversationModel` and chat lifecycle callbacks.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XcodeGen, xcodebuild via `make`, PositronicKit local path dependency.

## Global Constraints

- App target (`Sources/Yakamoz`) imports only SwiftUI/SwiftData/`YakamozCore`; reusable logic stays in `YakamozCore` or upstream.
- Match the test framework already used in each file; do not mix XCTest and Swift Testing in the same file.
- TDD throughout: write the failing test first, verify the failure, then add the minimal production change.
- Update each completed ticket file and `docs/tickets/README.md` in the same change.
- Trust `make verify`; do not treat bare `swift test` as sufficient verification for Yakamoz.
- Commit only ticket-owned files; do not blanket-stage unrelated changes.

---

### Task 0: Checkpoint Existing TF1-TF4 Work

**Files:**
- Modify: existing dirty files only if verification reveals a defect

**Interfaces:**
- Consumes: current working tree changes for `YAK-TF1` through `YAK-TF4`
- Produces: a clean committed base for the next ticket batch

- [ ] **Step 1: Run targeted terminal tests for the current dirty batch**

Run:
```bash
make test TEST_FILTER=TerminalSessionTests
make test TEST_FILTER=TerminalSessionRegistryTests
make test TEST_FILTER=TerminalToolsTests
```

Expected: PASS for the terminal session, registry, and tool suites.

- [ ] **Step 2: Commit the checkpoint if green**

Run:
```bash
git add Sources/YakamozCore/Tools/Terminal/TerminalTools.swift \
  Sources/YakamozCore/Workspaces/Terminal/TerminalSession.swift \
  Sources/YakamozCore/Workspaces/Terminal/TerminalSessionRegistry.swift \
  Tests/YakamozTests/TerminalSessionRegistryTests.swift \
  Tests/YakamozTests/TerminalSessionTests.swift \
  Tests/YakamozTests/TerminalToolsTests.swift \
  docs/tickets/README.md \
  docs/tickets/YAK-TF1-send-input-approval-bypass.md \
  docs/tickets/YAK-TF2-registry-double-spawn-race.md \
  docs/tickets/YAK-TF3-partial-output-duplication.md \
  docs/tickets/YAK-TF4-unbounded-buffer-growth.md \
  CLAUDE.md AGENTS.md
git commit -m "fix: land terminal follow-up tickets tf1-tf4"
```

Expected: one checkpoint commit that leaves only the next-ticket work uncommitted.

### Task 1: Land YAK-TF5 Approval Scoping

**Files:**
- Modify: `Sources/Yakamoz/Views/TerminalApprovalBanner.swift`
- Modify: `Sources/Yakamoz/Views/ChatView.swift`
- Modify: `Sources/YakamozCore/Workspaces/Terminal/MainActorApprover.swift`
- Modify: `Tests/YakamozTests/TerminalApprovalTests.swift`
- Modify: `docs/tickets/README.md`
- Modify: `docs/tickets/YAK-TF5-approval-banner-conversation-scoping.md`

**Interfaces:**
- Consumes: `PendingApproval.workspaceId`, `attachedTerminalWorkspaces`
- Produces: scoped pending-approval selection for one conversation’s banner

- [ ] **Step 1: Add a failing approval-scoping test**
- [ ] **Step 2: Implement a small testable scoped-selection helper on the approver seam**
- [ ] **Step 3: Thread `workspaceIds` from `ChatView` into `TerminalApprovalBanner`**
- [ ] **Step 4: Re-run `make test TEST_FILTER=TerminalApprovalTests`**
- [ ] **Step 5: Mark the ticket done and commit**

Commit:
```bash
git commit -m "fix: scope terminal approvals to the active conversation"
```

### Task 2: Land YAK-TF6 Workspace Detach Cleanup

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift`
- Modify: `Sources/Yakamoz/Views/WorkspacePicker.swift`
- Modify: `Sources/Yakamoz/YakamozApp.swift`
- Modify: `Tests/YakamozTests/WorkspaceConsistencyTests.swift`
- Modify: `docs/tickets/README.md`
- Modify: `docs/tickets/YAK-TF6-minor-cleanup.md`

**Interfaces:**
- Consumes: `WorkspaceAttachmentSupport.pruneOrphanWorkspaces(modelContext:)`
- Produces: `detachWorkspace(...) -> [UUID]` returning pruned terminal ids

- [ ] **Step 1: Add failing detach tests for orphan pruning and shared-reference retention**
- [ ] **Step 2: Change `detachWorkspace` to return pruned terminal ids and update `WorkspacePicker.detach` to use them**
- [ ] **Step 3: Clarify the best-effort termination comment in `YakamozApp` instead of adding a handshake**
- [ ] **Step 4: Re-run `make test TEST_FILTER=WorkspaceConsistencyTests`**
- [ ] **Step 5: Mark the ticket done and commit**

Commit:
```bash
git commit -m "fix: prune orphan workspaces on detach"
```

### Task 3: Land YAK-27 Assistant Markdown Rendering

**Files:**
- Create: `Sources/YakamozCore/Chat/AssistantMarkdownRenderer.swift`
- Modify: `Sources/Yakamoz/Views/MessageBubble.swift`
- Create: `Tests/YakamozTests/AssistantMarkdownRendererTests.swift`
- Modify: `docs/tickets/README.md`
- Modify: `docs/tickets/YAK-27-markdown-visualizer.md`

**Interfaces:**
- Consumes: `ChatTurnState.response.reconstructedText`
- Produces: `AttributedString` markdown rendering with plain-text fallback

- [ ] **Step 1: Add failing renderer tests for markdown parsing and malformed-markdown fallback**
- [ ] **Step 2: Implement the helper with `AttributedString(markdown:)` and a plain-text fallback**
- [ ] **Step 3: Swap the assistant text branch in `MessageBubble` to the renderer output while keeping tool rows and selection intact**
- [ ] **Step 4: Re-run `make test TEST_FILTER=AssistantMarkdownRendererTests`**
- [ ] **Step 5: Mark the ticket done and commit**

Commit:
```bash
git commit -m "feat: render assistant markdown in chat bubbles"
```

### Task 4: Land YAK-28 Settings-First Quick Model Switching

**Files:**
- Create: `Sources/YakamozCore/Configuration/ModelCatalogService.swift`
- Modify: `Sources/YakamozCore/Configuration/ProviderSettings.swift`
- Modify: `Sources/YakamozCore/Runtime/YakamozRuntime.swift`
- Modify: `Sources/Yakamoz/Views/SettingsView.swift`
- Modify: `Tests/YakamozTests/ProviderConfigurationTests.swift`
- Modify: `Tests/YakamozTests/RuntimeCompositionTests.swift`
- Modify: `docs/tickets/README.md`
- Modify: `docs/tickets/YAK-28-quick-model-switching.md`

**Interfaces:**
- Consumes: latest `ProviderSettingsSnapshot`, stored API key, provider `/models` responses
- Produces: ranked model catalog entries plus persisted favorites/recents per provider scope

- [ ] **Step 1: Add failing ranking/persistence tests in `ProviderConfigurationTests`**
- [ ] **Step 2: Add a runtime catalog-fetch test in `RuntimeCompositionTests`**
- [ ] **Step 3: Implement provider/baseURL-scoped favorites/recents persistence and ranking helpers**
- [ ] **Step 4: Add a runtime-backed catalog fetch seam and a Settings picker UI with manual fallback**
- [ ] **Step 5: Re-run focused tests, mark the ticket done, and commit**

Commit:
```bash
git commit -m "feat: add quick model switching in settings"
```

### Task 5: Land YAK-29 Timeline State Dots

**Files:**
- Modify: `Sources/YakamozCore/Models/PersistenceModels.swift`
- Modify: `Sources/YakamozCore/Chat/ChatEventReducer.swift`
- Modify: `Sources/YakamozCore/Chat/ChatViewModel.swift`
- Modify: `Sources/Yakamoz/Views/ChatView.swift`
- Modify: `Sources/Yakamoz/Views/ConversationListView.swift`
- Modify: `Tests/YakamozTests/ChatEventReducerTests.swift`
- Modify: `Tests/YakamozTests/ChatViewModelTests.swift`
- Modify: `docs/tickets/README.md`
- Modify: `docs/tickets/YAK-29-timeline-state-dots.md`

**Interfaces:**
- Consumes: chat lifecycle events and tool-trace state
- Produces: persisted `ConversationTimelineState` plus sidebar ranking/dot rendering

- [ ] **Step 1: Add failing reducer tests for `.tooling`, `.completed`, `.cancelled`, and `.failed`**
- [ ] **Step 2: Add failing `ChatViewModel` callback tests for immediate `.running` and terminal transitions**
- [ ] **Step 3: Persist the sidebar-facing state on `ConversationModel` and publish changes from `ChatViewModel`**
- [ ] **Step 4: Render the state dot and list ordering in `ConversationListView` without regressing the YAK-21 list-jump behavior**
- [ ] **Step 5: Re-run focused tests, mark the ticket done, and commit**

Commit:
```bash
git commit -m "feat: add timeline state dots to the conversation list"
```

### Task 6: Final Verification

**Files:**
- None unless verification exposes a defect

**Interfaces:**
- Consumes: all task commits
- Produces: verified batch ready for review

- [ ] **Step 1: Run the full gate**

Run:
```bash
make verify
```

Expected: green build and test gate with non-zero executed test count.

- [ ] **Step 2: Review git status and commit list**

Run:
```bash
git status --short
git log --oneline --decorate -n 8
```

Expected: only intended ticket files changed, with one commit per landed ticket plus the initial checkpoint commit.
