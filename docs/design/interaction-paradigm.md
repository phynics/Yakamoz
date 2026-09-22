# Interaction paradigm (2026-09 revision)

Status: accepted — decision recorded in [ADR 0003](../adr/0003-inspector-is-glass.md).

Yakamoz grew feature by feature (operators, workspaces, terminals, sidecars, the inspector's
Compose mode, the Gnostic client), and each feature put its controls wherever it fit at the
time. This document describes the interaction model the app follows from now on, the
problems it fixes, and the order it lands in.

## 1. What's wrong today

Evidence is from the code as of `91f8b04`.

| # | Problem | Evidence |
|---|---------|----------|
| P1 | **Conversation setup disappears after the first message.** Provider, workspace, and tool controls live in the inspector's Compose mode. Sending a message auto-selects the new turn, which flips the inspector to Inspect, so the controls vanish until the user finds the ⓧ "Return to compose" button. | `ChatViewModel` sets `selectedInspectionTurnIndex` in `send`; `RightPanePresentation.mode` is `.compose` only when that is `nil`. |
| P2 | **The same concept is controlled from three or four places.** Workspaces can be attached from toolbar chips (`WorkspacePicker`), the Compose pane (`WorkspaceInspectorView`, which only ever shows the *first* folder), an auto-injected "Attach a folder?" transcript row, and the Workspace Library sheet in the sidebar's **+** menu. | `ChatView.offerWorkspacePromptIfNeeded`, `InspectorDrawer.composeContent`, `AgentSidebarView` toolbar |
| P3 | **Global settings look per-conversation.** The provider/model menu sits in each conversation's Compose pane, but it edits the single app-wide `ProviderSettings`. | `ProviderControlMenu(settings:)` in `InspectorDrawer` |
| P4 | **Operator settings that do nothing.** "Default Model" and default tool toggles persist to `AgentModel` but nothing reads them; the model is always `ProviderSettings.model`. | `AgentSettingsView`; no reader of `defaultModel`/`defaultEnabledToolIds` outside the store |
| P5 | **Two different chat surfaces for the same thing.** Selecting an agent shows a segmented Chat/Vault/Settings page with the home conversation embedded under it; selecting any other conversation shows `ChatView` directly. The embedded chat pushes its toolbar under a second title bar. | `AgentDetailView` |
| P6 | **The inspector has hidden modes.** ⌘1–⌘5 are documented no-ops in Compose; the tab bar only exists after you click a bubble. | `AppCommands.swift` UIX-3 note |
| P7 | **Vocabulary drift.** The UI says "Agent" and "Timeline" where `CONTEXT.md` prescribes **Operator** and **Conversation**, and "Timeline" is now also the Gnostic term. | Sidebar title "Agents", "New Timeline", "Delete Agent" |
| P8 | **Jargon and one-item menus.** The toolbar "Options" menu holds a single toggle named "Sidecar Directives". | `SidecarControls` |
| P9 | **A hand-built inspector.** A custom drawer re-implements resizing, width clamping, and a resize handle that the system `.inspector` already provides, and it doesn't integrate with the window toolbar. | `InspectorDrawer`, `InspectorWidthClamping` |
| P10 | **Local and network chats use different control patterns.** The network chat has a single Workspaces menu button; the local chat has a row of chips plus a separate picker. | `NetworkWorkspaceMenu` vs `WorkspacePicker` |

## 2. Principles

1. **Every setting has one home, next to its owner.** App-wide → Settings (and a toolbar
   indicator). Conversation → the conversation's toolbar. Operator → the operator window.
   Nothing configurable lives in the inspector.
2. **The inspector is glass.** Its only job is the showcase: showing what the pipeline did
   for a turn. It never hides configuration and never changes mode under you.
3. **Same thing, same surface.** Every conversation — an operator's home, an operator's
   other conversations, an unassigned one — opens in the same `ChatView`. Network timelines
   reuse the same toolbar vocabulary.
4. **Show state, not just actions.** Toolbar controls name what is set ("Ada",
   "2 Workspaces", "5 Tools", the model), so the current configuration is visible at a
   glance without opening anything.
5. **Use the platform.** Native `.inspector`, native windows for long-lived editors, native
   menus. Remove custom chrome whenever the system provides it.
6. **Use the domain words.** UI strings follow `CONTEXT.md`.

## 3. Target model

### 3.1 Window anatomy

```text
┌ Sidebar ───────────┬ Conversation ─────────────────────────────┬ Inspector ─────┐
│ Operators          │ Title                     [Ada ▾] [2 Workspaces ▾] [5 Tools ▾] [gpt-5 ▾] [ⓘ] │
│  ▸ Ada        ●    │ ┌ approvals (only when something is pending) ┐│ Prompt Sent …   │
│     Refactor plan  │ │                                             ││ Turn 4 · latest │
│  ▸ Scout           │ │ transcript                                  ││                 │
│ Unassigned         │ │                                             ││  (glass only)   │
│   Scratch          │ └─────────────────────────────────────────────┘│                 │
│ Network   ● ⟳      │ composer                                       │                 │
│  ▸ Remote Ada      │                                                │                 │
└────────────────────┴────────────────────────────────────────────────┴─────────────────┘
```

### 3.2 Sidebar

- **Operators** section: selecting an operator row opens its **home conversation** directly
  in `ChatView`. Expanding the row lists the operator's other conversations. A context menu
  offers *Edit Operator…*, *New Conversation*, and *Delete Operator…*.
- **Unassigned** section: unchanged.
- **Network**: unchanged from the #31 pass (Ascendants → Gnostic Timelines, Network
  Workspaces).
- The **+** menu offers *New Operator* and *New Conversation*. The Workspace Library moves
  to the Workspaces menu (§3.3), where workspaces are actually used.

*Why:* P5. One click reaches the most common destination (talking to an operator), and the
chat surface is identical everywhere. Rejected: keeping a separate operator page as the
selection target, because it puts a tab bar and a second title above the chat, or forces
two clicks to reach the home conversation.

### 3.3 Conversation toolbar

Four menu buttons that show their current state, left to right, then the inspector toggle:

| Control | Shows | Contains |
|---------|-------|----------|
| **Operator** | operator name, or "Unassigned" | operators to assign (disabled on a home conversation), *Edit Operator…* |
| **Workspaces** | "Workspaces" or "N Workspaces" | one submenu per attached workspace (folders: *Create Terminal*, *Detach*; terminals: *Detach*); *Attach Folder…*, *New Terminal…*, *Attach from Library ▸*, *Manage Library…* |
| **Tools** | "N Tools" | grouped toggles (Built-in / Workspace / Terminal) with the existing last-tool guard; *Automatic Titles & Sections* (the sidecar toggle) |
| **Model** | the active model | the existing `ProviderControlMenu` contents; its help text states that it applies to all conversations |

*Why:* P1–P3, P8, P10. Configuration is always visible and reachable no matter which turn
is selected. The Workspaces button uses the same single-menu pattern as the network chat's
`NetworkWorkspaceMenu`. Rejected: a settings strip above the transcript, because it takes
vertical space in every conversation to duplicate what the toolbar can show.

The auto-injected "Attach a folder?" transcript row is removed. An empty conversation
instead shows an empty state with *Attach Folder…* as a suggestion, and the transcript only
ever contains the conversation.

### 3.4 Inspector

- Native `.inspector(isPresented:)` with `inspectorColumnWidth(min: 280, ideal: 360, max: 640)`,
  toggled by the toolbar button and ⌘I as today.
- Always the five tabs; ⌘1–⌘5 always work.
- **Follows the latest turn** when no bubble is selected. A header shows "Turn N · Latest",
  or "Turn N" with a *Latest* button when the user has pinned an older turn by clicking its
  bubble. Deselecting the bubble returns to following.
- Compose mode, `RightPanePresentation`, the custom drawer, and `InspectorWidthClamping`
  are deleted.

*Why:* P1, P6, P9. The showcase is the inspector; it should always show something
meaningful and never hold settings. Rejected: keeping Compose as a sixth tab, because
settings would still be hidden behind the inspector and would compete with the per-turn
tabs.

### 3.5 Operator window

*Edit Operator…* opens a dedicated window (`WindowGroup(for: UUID.self)`) with two tabs:
**Profile** (name, instructions, delete) and **Vault** (`NOTES.md` + Memory). The dead
"Default Model" and default-tool controls are removed; the model fields stay in the schema
(no migration) for a future per-operator model feature.

*Why:* P4, P5. The vault is a long-lived editor that you want next to the conversation, not
a modal sheet that blocks it. Removing controls that silently do nothing is more honest
than keeping them.

### 3.6 Vocabulary

"Agents" → "Operators"; "New Agent" → "New Operator"; "New Timeline"/"New Chat" → "New
Conversation"; "Delete Agent" → "Delete Operator". "Timeline" stays only for Gnostic
Timelines.

## 4. Delivery order

Each step is independently shippable and passes `make verify`.

1. **Vocabulary and dead controls** — §3.6, remove the dead operator defaults.
2. **Conversation toolbar** — §3.3: Operator/Workspaces/Tools/Model menus; remove the Options
   menu, the chips, and the transcript workspace prompt; add the empty state.
3. **Inspector is glass** — §3.4: native inspector, follow-latest, delete Compose.
4. **Operators open their home** — §3.2 and §3.5: operator selection → `ChatView`; operator
   window; delete `AgentDetailView`'s tab page.

## 5. Not changing

- Transcript rendering, streaming, scroll-follow behaviour, approval banners.
- The runtime, persistence, and `YakamozCore`/`YakamozNetwork` boundaries.
- The Settings scene's Provider and Network panes.

## 6. Risks

- **Muscle memory:** users who relied on clicking an operator to reach Vault/Settings now go
  through *Edit Operator…*. It's offered in the toolbar Operator menu and the row context menu.
- **Inspector width:** the native column doesn't clamp to 55 % of the detail width the way
  the custom drawer did. The window's minimum width (900 pt) and the column's max (640 pt)
  keep the transcript usable.
- **Removed onboarding nudge:** the empty state replaces the "Attach a folder?" row. It's
  less forceful, but it no longer pollutes the transcript.
