# YAK-18 — Inspector Tools tab: group tools by workspace vs built-in

- **Status:** Done
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The Tools tab lists all available tools in one flat list. They should be grouped so it's
clear which tools are **built-in** (always available) vs **workspace** tools (only present
when a folder is attached, and confined to it).

## Proposed approach
- In `ToolsInspectorView`, split `availableToolsSection` into two labeled groups using the
  existing `ConversationToolOption.requiresWorkspace` flag: "Built-in" (`requiresWorkspace
  == false`: calculator, current_datetime) and "Workspace" (`requiresWorkspace == true`:
  the filesystem tools).
- Show the Workspace group only when a workspace is attached (it's already empty
  otherwise), optionally with the attached folder name as the section header.
- Keep the existing per-tool toggle behavior (YAK-8) unchanged within each group.

## Acceptance criteria
- Tools tab shows two clearly-labeled groups; toggles still work per tool.
- Workspace group reflects attach/detach.
- `make verify` green.

## Pointers
- `Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift` (`availableToolsSection`)
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift` (`ConversationToolOption.requiresWorkspace`, `toolOptions(hasWorkspace:)`)
