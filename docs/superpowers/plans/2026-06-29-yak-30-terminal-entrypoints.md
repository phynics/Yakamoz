# YAK-30 Terminal Workspace Entrypoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class terminal-workspace entrypoints so a user can create a terminal from a new conversation, from an attached folder, and from the Tools inspector without hunting through the folder chip menu.

**Architecture:** Keep persistence and duplicate-handling in `WorkspaceAttachmentSupport`, with SwiftUI surfaces delegating to the same creation helpers. Expand `WorkspacePicker` into an "Add Workspace" entrypoint and thread a terminal-creation callback from `ChatView` into `ToolsInspectorView` so the inspector can surface the same flow with safety copy.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XcodeGen, `make`/`xcodebuild`.

## Global Constraints

- App-target views stay in `Sources/Yakamoz`; persistence and reusable logic stay in `YakamozCore`.
- Follow TDD strictly: add a failing test, verify it fails, then add the minimal implementation.
- Reuse one terminal-creation path; do not fork folder-picking or terminal-attach logic across views.
- Keep the existing folder-chip affordance, but improve discoverability and accessibility labels/help.
- Update `docs/tickets/YAK-30-terminal-workspace-entrypoints.md` and `docs/tickets/README.md` in the same change.
- Final verification for the branch is `make verify`.

---

### Task 1: Add reusable terminal-creation helpers and coverage

**Files:**
- Modify: `Sources/YakamozCore/Tools/ConversationToolSupport.swift`
- Modify: `Tests/YakamozTests/ConversationAttachmentTests.swift`

**Interfaces:**
- Consumes: `attachWorkspace(to:modelContext:url:)`, `attachTerminal(to:fromFolder:modelContext:)`
- Produces: one helper that creates/reuses a folder attachment from a chosen URL and one helper that reuses an existing terminal for an attached folder when appropriate

- [ ] **Step 1: Add a failing test for creating a terminal from a picked folder URL**
- [ ] **Step 2: Add a failing test for avoiding duplicate terminal workspaces for the same folder in one conversation**
- [ ] **Step 3: Implement the minimal helper(s) in `WorkspaceAttachmentSupport`**
- [ ] **Step 4: Run `make test TEST_FILTER=ConversationAttachmentTests` and confirm green**

### Task 2: Wire first-class UI entrypoints and safety copy

**Files:**
- Modify: `Sources/Yakamoz/Views/WorkspacePicker.swift`
- Modify: `Sources/Yakamoz/Views/ChatView.swift`
- Modify: `Sources/Yakamoz/Views/Inspector/InspectorDrawer.swift`
- Modify: `Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift`
- Modify: `docs/tickets/YAK-30-terminal-workspace-entrypoints.md`
- Modify: `docs/tickets/README.md`

**Interfaces:**
- Consumes: Task 1 terminal-creation helper(s)
- Produces: an add-workspace menu, inspector CTA, and shared terminal-creation flow with safety copy

- [ ] **Step 1: Expand `WorkspacePicker` to expose "Folder" and "Terminal" from the empty state and plus button**
- [ ] **Step 2: Add shared folder-picking / safety-copy flow for terminal creation from `WorkspacePicker`**
- [ ] **Step 3: Thread a terminal-creation callback from `ChatView` through `InspectorDrawer` into `ToolsInspectorView`**
- [ ] **Step 4: Show a no-terminal CTA in `ToolsInspectorView` when terminal tools are unavailable**
- [ ] **Step 5: Run focused verification for affected tests, then `make verify`**

