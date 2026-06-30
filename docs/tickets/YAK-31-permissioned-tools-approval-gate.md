# YAK-31 - [SECURITY] Permissioned tools execute without an approval gate

- **Status:** Done — `ToolRouter` now consults an injected `ToolApprovalGate` at its single local-execution
  sink (`executeLocally`, before `executeWithTimeout`) for any tool whose `requiresPermission` is true,
  covering both structured provider tool calls and the text-fallback `<tool_call>` path (they converge
  there). The gate defaults to `DenyAllToolApprovalGate` so permissioned tools never execute without an
  explicit approval decision; a denied call throws the new `ToolError.permissionDenied`. Yakamoz injects
  a `MainActorToolApprover` (a UI-bridging `ToolApprovalGate`, mirroring the terminal `MainActorApprover`)
  and renders a `ToolApprovalBanner`, giving its permissioned filesystem tools a visible approval UX;
  `terminal_run` is auto-approved by this gate since it keeps its own `TerminalCommandApproving` gate.
  Tests: `ToolRouterTests` (structured deny/approve, text-fallback deny, non-permissioned regression),
  `ToolApprovalTests` (Yakamoz approver approve/deny/self-gated).
- **Priority:** High
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

`Tool.requiresPermission` promises that permissioned tools prompt for explicit user
approval, but `ToolRouter` executes the resolved `AnyTool` without checking that
flag. Yakamoz relies on PositronicKit for live agent tool execution, so a model-emitted
or fallback-parsed tool call can invoke permission-marked tools unless every Yakamoz
caller has already enforced a separate approval gate.

This overlaps with Yakamoz's terminal approval model: terminal tools have their own
approver, but filesystem and other PositronicKit tools still depend on the shared
runtime contract.

## Affected code

- `../PositronicKit/Sources/PKShared/Tools/Tool.swift:17`
- `../PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift:326`
- `../PositronicKit/Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift:31`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` - live `AnyTool` composition

## Before / after

### Before

```swift
let result = try await executeWithTimeout(
    tool: resolvedTool,
    arguments: arguments,
    timeout: toolExecutionTimeout
)
```

### After

```swift
guard !resolvedTool.requiresPermission || try await approvalGate.approve(tool: resolvedTool, arguments: arguments) else {
    throw ToolError.permissionDenied(resolvedTool.name)
}

let result = try await executeWithTimeout(
    tool: resolvedTool,
    arguments: arguments,
    timeout: toolExecutionTimeout
)
```

Exact API shape is up to the implementation, but the approval check must live at the
runtime execution sink, not only in Yakamoz UI code.

## Tests

- PositronicKit: a permissioned fake tool is not executed from a structured tool call
  until approval is present.
- PositronicKit: the same fake tool is not executed from the text fallback
  `<tool_call>` path until approval is present.
- Yakamoz: live runtime composition injects an approval path or explicitly disables
  permissioned tools that cannot be approved.
- Regression: non-permissioned tools still execute normally.

## Acceptance criteria

- `ToolRouter` cannot execute a permissioned tool without an explicit approval decision.
- Text fallback tool calls and structured provider tool calls follow the same approval path.
- Yakamoz has a visible approval UX or a safe disabled state for any permissioned tool it exposes.
- PositronicKit verification and Yakamoz `make verify` are green.
