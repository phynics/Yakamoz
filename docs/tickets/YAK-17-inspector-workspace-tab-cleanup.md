# YAK-17 — Inspector Workspace tab: drop the file list, add a detach action

- **Status:** Done
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The Workspace inspector tab currently renders a file listing of the attached folder,
which the user finds unnecessary, and offers no way to **detach** the workspace from the
tab.

## Proposed approach
- Remove the file-list portion of the Workspace tab (keep the essential workspace
  identity/summary: name + root path + attached state).
- Add a **Detach** button that clears `conversation.workspaceId` (reuse the existing
  `detachWorkspace` flow already wired in `ChatView`), so filesystem tools are removed and
  the Workspace presentation clears (per the existing `workspaceId` change tasks).
- Confirm the live `WorkspacePresentation.build` no longer needs to enumerate files if
  nothing renders them (avoid unnecessary directory walks).

## Acceptance criteria
- Workspace tab shows no file list; shows name/path/attached state.
- A Detach action removes the workspace mid-conversation; tools and presentation update
  without reopening the conversation.
- `make verify` green.

## Pointers
- `Sources/Yakamoz/Views/Inspector/WorkspaceInspectorView.swift`
- `Sources/Yakamoz/Views/ChatView.swift` (`detachWorkspace`, `refreshWorkspacePresentation`, `onDetachWorkspace`)
- `Sources/YakamozCore/Workspaces/WorkspacePresentation.swift` (`build`, file enumeration)
