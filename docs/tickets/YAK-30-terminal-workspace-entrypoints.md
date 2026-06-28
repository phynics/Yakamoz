# YAK-30 — Terminal workspace entrypoints

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** product follow-up (2026-06-28)

## Problem

Terminal workspace support exists, but there is no obvious entrypoint for a user who has not
already discovered the folder chip menu. The current UI creates a terminal only from the menu
inside an attached folder chip:

```swift
// Sources/Yakamoz/Views/WorkspacePicker.swift:56
Menu {
    Button {
        createTerminal(from: workspace)
    } label: {
        Label("Create Terminal", systemImage: "terminal")
    }
```

That satisfies a contextual power-user path, but it is too hidden for the core user story:
"I want to give the agent a terminal for this project." A user starting from a new
conversation sees "Attach Folder", not "Terminal"; a user looking at the Tools inspector sees
tool toggles only after a terminal is already attached; and a user who understands terminal
workspaces as a separate workspace type has no direct "create terminal workspace" affordance.

## User Stories

1. As a developer starting a fresh conversation, I can choose "Terminal Workspace" directly,
   then select the folder it should start in, so I do not have to discover that terminals are
   hidden behind folder chips.
2. As a developer who already attached a folder, I can create a terminal for that folder from
   a nearby contextual action, so the terminal inherits the expected working directory.
3. As a developer looking at the Tools inspector, I can tell that terminal tools require a
   terminal workspace and create/attach one from that same surface.
4. As a cautious user, I see copy that makes the unjailed-shell approval model clear before
   creating the terminal, so the entrypoint does not hide the safety tradeoff documented in
   the README.
5. As a keyboard-focused user, I can reach the terminal creation flow without precise chip
   menu targeting, and the controls have stable accessibility labels.

## Approaches Considered

- **Recommended: add a first-class workspace add menu.** Replace the single empty-state
  "Attach Folder" button with an "Add Workspace" menu offering "Folder" and "Terminal".
  "Terminal" opens a folder picker, attaches the folder if needed, then creates and attaches
  the terminal rooted at that folder. Keep the folder-chip "Create Terminal" action.
- **Inspector-only entrypoint.** Add a call-to-action in the Tools tab when no terminal is
  attached. This helps users who inspect tools, but it does not solve first-run discoverability.
- **Toolbar command only.** Add a global "Create Terminal" toolbar/menu command. This is fast
  once learned, but it would be detached from the workspace state and risks duplicating the
  picker logic in another place.

Prefer the first approach, with the Tools-tab call-to-action as a supporting entrypoint.

## Task

- Add a reusable creation helper that can create a terminal from an existing folder workspace
  or from a folder URL selected specifically for terminal creation.
- Change the workspace picker empty state from only "Attach Folder" to an "Add Workspace"
  affordance with "Folder" and "Terminal" choices.
- Keep the existing folder-chip "Create Terminal" action, but make sure it is discoverable
  via help/accessibility labels and does not create duplicate terminal workspaces for the same
  conversation/folder unless the user explicitly asks for another.
- Add a Tools-inspector empty/disabled-state affordance that explains terminal tools require
  an attached terminal workspace and invokes the same terminal creation flow.
- Include concise safety copy in the terminal creation path: the shell starts in the chosen
  folder, is not jailed to it, and each command is approval-gated unless the user allows the
  terminal for the session.

## Affected Code

- `Sources/Yakamoz/Views/WorkspacePicker.swift:24` — empty state currently only attaches a
  folder.
- `Sources/Yakamoz/Views/WorkspacePicker.swift:56` — terminal creation exists only inside a
  folder chip menu.
- `Sources/Yakamoz/Views/ChatView.swift:197` — passes inspector callbacks; likely needs a
  terminal-creation callback alongside folder attach/detach/tool toggles.
- `Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift:55` — available tools are grouped,
  but terminal tools are absent when no terminal workspace is attached and there is no creation
  affordance.
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift:247` — existing
  `attachTerminal(to:fromFolder:modelContext:)` should remain the single persistence path.

## Tests

- Add a focused helper test proving terminal creation from a folder URL inserts/attaches the
  expected folder and terminal workspaces and enables terminal tool ids.
- Add a duplicate-prevention test for "create terminal for this attached folder" if the UI is
  expected to reuse an existing terminal.
- Add SwiftUI view tests where practical for:
  - empty workspace picker exposes both folder and terminal choices;
  - a folder chip still exposes "Create Terminal";
  - Tools inspector shows a terminal creation affordance when no terminal is attached.

## Acceptance Criteria

- A new conversation exposes a visible path to create a terminal workspace without first
  attaching a folder through a hidden prerequisite flow.
- Creating a terminal from the first-class entrypoint asks for a starting folder and results in
  a terminal workspace attached to the conversation.
- Creating a terminal from an existing folder chip still works and uses that folder as the
  shell root.
- The Tools inspector gives users a clear path from "terminal tools unavailable" to "create a
  terminal workspace".
- The creation flow surfaces the unjailed-shell / approval-gated command model before
  attaching the terminal.
- Accessibility labels and help text describe "Attach folder workspace", "Create terminal
  workspace", and "Create terminal for <folder>" distinctly.
- `make verify` is green in Yakamoz.
