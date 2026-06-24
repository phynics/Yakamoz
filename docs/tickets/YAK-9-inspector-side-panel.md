# YAK-9 — Move the Inspector from a bottom drawer to a side panel

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** post-CP11 follow-up request (revises an earlier design decision)

## Problem

During brainstorming, the design spec deliberately chose Layout **B** — chat
as the default view with a collapsible, Xcode-style **bottom** Inspector
drawer — over Layout **C** (an Inspector-forward 50/50 side-by-side split).
This was implemented in CP8/CP9: `ChatView.chatBody` hosts `InspectorDrawer`
via `GeometryReader` + `.overlay(alignment: .bottom)`
(`Sources/Yakamoz/Views/ChatView.swift:130-148`), with `isInspectorOpen`/
`selectedInspectorTabRaw` persisted via `@SceneStorage`.

The user now wants the Inspector moved to the **side** instead, reversing that
specific layout call (closer to the originally-rejected Option C, but as a
toggleable side panel rather than a fixed 50/50 split).

## Proposed approach

Replace the bottom-overlay hosting with a trailing side column:

- Use `NavigationSplitView` (or a manually-sized `HStack` + `Divider` with a
  draggable/animatable width) with the conversation transcript as the primary
  content and `InspectorDrawer`'s tab content as a trailing detail column.
- Keep the existing `InspectorTab` enum, tab views (`PromptInspectorView`,
  `SentInspectorView`, `JournalInspectorView`, `ResponseInspectorView`,
  `ToolsInspectorView`, `WorkspaceInspectorView`), and `isInspectorOpen`/
  `selectedInspectorTabRaw` `@SceneStorage` state — only the container/hosting
  changes, not the tab contents or persistence keys (avoid losing user
  preferences in existing `@SceneStorage` values).
- Keep the ⌘I toggle and ⌘1–6 tab-selection shortcuts (`coordinator.toggleInspectorToken`,
  `coordinator.inspectorTabRequest`, `ChatView.swift:100-111`) working unchanged.
- Decide on a reasonable default/min/max width for the side panel and whether
  it's resizable.

## Acceptance criteria
- Inspector renders as a trailing side panel, not a bottom overlay.
- ⌘I toggle and ⌘1–6 tab shortcuts still work.
- Existing inspector tab content/view models are reused as-is (no behavior
  changes to what each tab shows).
- `Sources/Yakamoz/Views/Inspector/InspectorDrawer.swift` (or its replacement)
  still composes the same six tab views.

## Pointers
- `Sources/Yakamoz/Views/ChatView.swift:130-148` (current bottom-overlay hosting)
- `Sources/Yakamoz/Views/Inspector/InspectorDrawer.swift`
- `docs/superpowers/specs/2026-06-22-yakamoz-design.md` (original Layout B vs C decision — note this ticket intentionally revises that choice)
