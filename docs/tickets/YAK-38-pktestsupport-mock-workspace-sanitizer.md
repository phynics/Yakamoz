# YAK-38 - [BUG] Exported `MockLocalWorkspace` omits path containment checks

- **Status:** Done
- **Resolution:** Added `PathSanitizer.safelyResolve` to `readFile`, `writeFile`, and `deleteFile` in `MockLocalWorkspace`; new traversal-rejection tests added.
- **Priority:** Low
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

`PKTestSupport` is an exported package product used by downstream tests. Its
`MockLocalWorkspace` directly appends caller-controlled paths to `rootURL` for read,
write, and delete operations. That behavior diverges from production filesystem tools,
which use `PathSanitizer`.

This is low priority because the surface is test support, but Yakamoz uses
`PKTestSupport` patterns heavily and should not normalize unsafe helper behavior.

## Affected code

- `../PositronicKit/Package.swift:16`
- `../PositronicKit/Tests/PKTestSupport/MockLocalWorkspace.swift:35`
- Yakamoz tests that use local/mock workspaces

## Before / after

### Before

```swift
let url = rootURL.appendingPathComponent(path)
return try String(contentsOf: url, encoding: .utf8)
```

### After

```swift
let url = try PathSanitizer.safelyResolve(
    path: path,
    within: rootURL.path,
    jailRoot: rootURL.path
)
return try String(contentsOf: url, encoding: .utf8)
```

## Tests

- `readFile("../outside")`, `writeFile("../outside")`, and `deleteFile("../outside")` are rejected.
- Symlink-to-outside paths are rejected.
- Existing safe mock workspace tests still pass.
- Yakamoz test helpers do not depend on traversal behavior.

## Acceptance criteria

- Exported test-support workspace helpers enforce the same containment invariant as production helpers.
- Any intentionally unsafe mock behavior is explicitly named and documented as trusted-input-only.
- PositronicKit verification and Yakamoz `make verify` are green.
