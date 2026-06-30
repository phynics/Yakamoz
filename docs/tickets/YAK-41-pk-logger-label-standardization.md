# YAK-41 - PositronicKit: stable, consistent swift-log labels

- **Status:** Done
- **Priority:** Medium
- **Repos:** PositronicKit (+ Monad/Shuttle call-site sweep)
- **Spec:** `../../Yakamoz/docs/superpowers/specs/2026-06-30-logging-debuggability-design.md`
- **Related:** YAK-40 (Yakamoz consumes this), YAK-42 (PK metadata/levels)

## Problem

PositronicKit's log labels are host-dependent and inconsistent, so even with a configured
backend they are hard to filter:

- `Logger.module(named:)` derives its subsystem from `Bundle.main.bundleIdentifier ??
  "com.positronickit.core"` (`Sources/PKShared/Utilities/Logger+Extensions.swift:11`). Loaded
  by Yakamoz, every label becomes `me.atkn.Yakamoz.<name>` — host-dependent, and **double-prefixed**
  where `name` already starts with `com.positronickit.`.
- Call sites disagree on the `name` argument:
  - `Logger.module(named: "com.positronickit.chat-engine")` — `ChatEngine.swift:64`
  - `Logger.module(named: "retry-policy")` — `Utilities/RetryPolicy.swift:7`
  - `Logger.module(named: "TimelineArchiver")` — `Services/Timeline/TimelineArchiver.swift:18`
  - `Logger.module(named: "com.positronickit.ContextManager")` — `Services/Context/ContextManager.swift:11`
- Two sites bypass `.module` and construct a `Logger(label:)` **per call**:
  - `Services/Timeline/TimelineToolManager.swift:71` and `:82` (inside a closure)
  - `Models/Tools/Tool+OpenAI.swift:15` (inline at the warning site)

## Affected code

- `Sources/PKShared/Utilities/Logger+Extensions.swift:11`
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift:64`
- `Sources/PositronicKit/Utilities/RetryPolicy.swift:7`
- `Sources/PositronicKit/Services/Timeline/TimelineArchiver.swift:18`
- `Sources/PositronicKit/Services/Context/ContextManager.swift:11` (+ `ContextAssemblyStage`/`NoteDiscoveryStage`/`QueryAugmentationStage`/`MemoryRetrievalStage` labels)
- `Sources/PositronicKit/Services/Timeline/TimelineToolManager.swift:71,82`
- `Sources/PositronicKit/Models/Tools/Tool+OpenAI.swift:15`
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift:88` (verify label form)
- Monad/Shuttle call sites + PK docs that reference the old label strings.

## Before / after

### Before

```swift
private static var subsystem: String { Bundle.main.bundleIdentifier ?? "com.positronickit.core" }
public static func module(named name: String) -> Logger { Logger(label: "\(subsystem).\(name)") }

Logger.module(named: "com.positronickit.chat-engine")          // double-prefixes under a host
let logger = Logger(label: "com.positronickit.session-tool-manager")   // per-call, in a closure
```

### After

```swift
public enum PKLogSubsystem { public static let value = "com.positronickit" }
public static func module(named name: String) -> Logger {
    // `name` is a bare category, e.g. "chat-engine" — never pre-prefixed.
    Logger(label: "\(PKLogSubsystem.value).\(name)")
}

Logger.module(named: "chat-engine")                            // -> com.positronickit.chat-engine
private let logger = Logger.module(named: "session-tool-manager")   // stored once on the type
```

Normalize all categories to lowercase dash form (`chat-engine`, `retry-policy`,
`context-manager`, `timeline-archiver`, `session-tool-manager`, `tools`, …).

## Tests

- `Logger.module(named:)` yields `com.positronickit.<name>` regardless of `Bundle.main`
  (no host prefix, no double prefix).
- No `Logger(label:)` constructed inside a function body / closure remains in the targeted files.

## Acceptance criteria

- PK labels are host-independent and consistently `com.positronickit.<category>`.
- Per-call `Logger(label:)` construction replaced with stored `Logger.module(named:)` loggers.
- Monad/Shuttle call sites and PK docs updated for any changed label strings (cross-repo rule).
- PositronicKit `make verify` (and Monad/Shuttle builds) green.
