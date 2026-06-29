# YAK-32 - [SECURITY] Agent workspace seed filenames can escape `Notes`

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

`AgentWorkspaceService.createAgentWorkspace` creates an agent `Notes` directory, then
writes every `AgentTemplate.workspaceFilesSeed` key with
`notesDir.appendingPathComponent(filename)`. A seed filename containing traversal
segments can write outside the intended notes directory.

Yakamoz should track this because agent templates and local workspaces are part of its
showcase surface, even if the core fix belongs upstream in PositronicKit.

## Affected code

- `../PositronicKit/Sources/PositronicKit/Services/Workspace/AgentWorkspaceService.swift:62`
- `../PositronicKit/Sources/PKShared/Utilities/PathSanitizer.swift`
- Yakamoz template/import code if it exposes `AgentTemplate.workspaceFilesSeed`

## Before / after

### Before

```swift
for (filename, content) in seed {
    try content.write(
        to: notesDir.appendingPathComponent(filename),
        atomically: true,
        encoding: .utf8
    )
}
```

### After

```swift
for (filename, content) in seed {
    let destination = try PathSanitizer.safelyResolve(
        path: filename,
        within: notesDir.path,
        jailRoot: notesDir.path
    )
    try content.write(to: destination, atomically: true, encoding: .utf8)
}
```

If nested seed files are supported, create intermediate directories only after the final
canonical destination is proven to remain under `Notes`.

## Tests

- Seed key `../outside.md` is rejected and does not create a file outside `Notes`.
- Absolute paths and symlink escapes are rejected.
- Safe seed names, and safe nested relative seed names if supported, still work.
- Yakamoz tests cover any local template-import path that can provide seed files.

## Acceptance criteria

- Template seed filenames cannot write outside the agent `Notes` directory.
- Rejected filenames return a user-friendly error.
- Yakamoz either inherits the upstream safe behavior or blocks lower-trust seed filenames before calling PositronicKit.
- PositronicKit verification and Yakamoz `make verify` are green.
