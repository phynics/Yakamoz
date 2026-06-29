# YAK-35 - [BUG] Filesystem search tools lack producer-side resource limits

- **Status:** Open
- **Priority:** Medium
- **Repos:** PositronicKit + Yakamoz
- **Surfaced by:** Codex Security scan of PositronicKit (`cf83525f5fc4_20260628T221104Z`)

## Problem

The built-in filesystem search tools are workspace-contained, but they do not bound work
before doing it:

- `SearchFilesTool` launches `/usr/bin/grep`, calls `waitUntilExit()`, and only then
  drains stdout/stderr and applies the 100-line display limit.
- `SearchFileContentTool` recursively reads full files with `String(contentsOf:)`; the
  50-result limit applies after file contents are loaded.

In Yakamoz, prompt-injected tool calls or hostile workspace contents can stall the local
runtime or consume memory/CPU.

## Affected code

- `../PositronicKit/Sources/PKShared/Tools/Filesystem/SearchFilesTool.swift:101`
- `../PositronicKit/Sources/PKShared/Tools/Filesystem/SearchFileContentTool.swift:103`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift` - exposes filesystem tools

## Before / after

### Before

```swift
try process.run()
process.waitUntilExit()

let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
```

### After

```swift
try process.run()
let outputTask = Task { try await outputPipe.fileHandleForReading.read(upToByteLimit: maxBytes) }
let status = try await process.waitUntilExit(timeout: timeout)
guard status.didExit else {
    process.terminate()
    return .failure("Search timed out")
}
```

For the Swift grep helper, stream line-by-line and stop when file, byte, match, or time
budgets are exhausted.

## Tests

- `SearchFilesTool` terminates a long-running or high-output subprocess at the configured limit.
- `SearchFileContentTool` rejects or skips files above a per-file byte limit.
- Recursive no-match searches stop at a total byte/file/time budget.
- Yakamoz tool execution surfaces resource-limit failures as normal tool failures, not a stuck assistant turn.

## Acceptance criteria

- Search tools enforce wall-clock, file-count, per-file byte, total byte, and output byte limits.
- Pipes are drained concurrently or otherwise cannot deadlock the subprocess.
- Existing normal searches still work.
- PositronicKit verification and Yakamoz `make verify` are green.
