# YAK-33 - [SECURITY] Invalid explicit `workspaceID` falls back to another workspace

- **Status:** Done
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

> **Resolution.** `ToolRouter.resolveWorkspace` now fails closed: an explicit
> `workspaceID` that is not among the timeline's attached/primary workspaces throws
> `ToolError.workspaceNotFound(explicitId)` instead of falling back to default
> resolution (`Sources/PositronicKit/Services/Tools/ToolRouter.swift:297`). An absent
> `workspaceID` still uses normal default resolution. The thrown `ToolError` already
> propagates to the agent-visible tool-result stream, so no Yakamoz runtime change was
> needed; a Yakamoz regression guard confirms tool routing still succeeds when no
> `workspaceID` is supplied. Also fixed a pre-existing build break: Monad's
> `ErrorMiddleware.classifyToolError` exhaustive switch was missing the
> `.permissionDenied` case added by YAK-31. Added three PositronicKit tests
> (invalid/unattached fail-closed, omitted-uses-default) plus the Yakamoz suite.
> Verified: PositronicKit 562 tests pass, Monad builds, Yakamoz `make verify` green.

## Problem

When a tool call supplies a `workspaceID` that is not attached to the current timeline,
`ToolRouter` logs a warning and falls back to default workspace resolution. In a
multi-workspace conversation, this can run a tool against a different workspace than the
explicit selector requested.

Yakamoz now supports multiple attached workspace kinds, including terminal workspaces,
so explicit workspace selection should fail closed.

## Affected code

- `../PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift:291`
- `Sources/YakamozCore/Tools/ConversationToolSupport.swift`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift`

## Before / after

### Before

```swift
guard candidates.contains(explicitId) else {
    logger.warning("Requested workspaceID \(explicitId) not found in timeline context. Falling back to default resolution.")
    return try await timelineManager.findWorkspaceForTool(tool, in: candidates)
}
```

### After

```swift
guard candidates.contains(explicitId) else {
    throw ToolError.workspaceNotFound(explicitId)
}
```

Absent `workspaceID` can still use default resolution. Invalid explicit identifiers must
not silently become a different workspace.

## Tests

- PositronicKit: invalid explicit `workspaceID` fails and does not execute the tool in the primary workspace.
- PositronicKit: unattached but well-formed `workspaceID` fails closed.
- PositronicKit: omitted `workspaceID` still uses normal default resolution.
- Yakamoz: folder and terminal workspaces with the same conversation do not cross-route when a stale id is supplied.

## Acceptance criteria

- Explicit workspace selectors are authoritative: select that workspace or fail.
- Yakamoz surfaces the routing failure as an agent-visible tool error.
- No fallback execution occurs for stale, unattached, or mistyped workspace identifiers.
- PositronicKit verification and Yakamoz `make verify` are green.
