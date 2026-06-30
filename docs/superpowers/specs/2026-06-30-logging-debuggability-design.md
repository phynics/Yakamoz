# Logging & Debuggability — Design Spec

- **Date:** 2026-06-30
- **Repos:** Yakamoz + PositronicKit
- **Status:** Approved design (pre-implementation)
- **Tickets:** YAK-40 (Yakamoz), YAK-41 + YAK-42 (PositronicKit)

## Goal

Make a running Yakamoz session debuggable. Today, when something goes wrong (failed
launch, failed turn, dropped tool call) there is **no usable diagnostic trail**:

- swift-log is never bootstrapped in Yakamoz, so PositronicKit's runtime diagnostics
  (chat pipeline, providers, retries, tool routing) are emitted into the default no-op /
  unconfigured handler and effectively vanish.
- PositronicKit's own labels are inconsistent and, under a GUI host, double-prefixed —
  so even with a backend they would be hard to filter in Console.app.
- Almost nothing carries structured metadata (conversation id, turn index, tool-call id),
  so logs can't be correlated to a specific failing interaction.
- Yakamoz swallows its setup error into a UI string and never logs it.

Scope is **developer-grade observability** for a local, single-user macOS showcase app:
unified logging (Console.app) via `os.Logger`. Explicitly **out of scope** for now: a
rotating file sink, a Settings verbose toggle, remote/telemetry, and prompt-assembly
verbose logs (the `promptAssemblyLogger` seam stays wired but `nil`).

## Current state (evidence)

### Yakamoz
- `Sources/Yakamoz/YakamozApp.swift` — no `LoggingSystem.bootstrap`; `init()`'s `catch`
  stuffs `error.localizedDescription` into `setupError` (a UI string) and logs nothing.
- `swift-log` (`import Logging`) is only used to thread an optional `promptAssemblyLogger`
  that every call site passes as `nil`
  (`Sources/YakamozCore/Chat/ChatViewModel.swift:220`,
  `Sources/YakamozCore/Runtime/YakamozRuntime.swift:291/304/448`).
- `ChatViewModel` catches turn errors and surfaces an inline UI message, but logs nothing.

### PositronicKit
- `Sources/PKShared/Utilities/Logger+Extensions.swift:11` — `Logger.module(named:)` derives
  its subsystem from `Bundle.main.bundleIdentifier ?? "com.positronickit.core"`. In Yakamoz
  the bundle id is `me.atkn.Yakamoz`, so labels become e.g.
  `me.atkn.Yakamoz.com.positronickit.chat-engine` — host-dependent and double-prefixed.
- Label scheme is inconsistent across call sites:
  - `Logger.module(named: "com.positronickit.chat-engine")` (ChatEngine.swift:64) — name already prefixed
  - `Logger.module(named: "retry-policy")` (RetryPolicy.swift:7) — bare name
  - `Logger.module(named: "TimelineArchiver")` (TimelineArchiver.swift:18) — PascalCase, bare
  - `Logger.module(named: "com.positronickit.ContextManager")` (ContextManager.swift:11) — prefixed + PascalCase
  - `Logger(label: "com.positronickit.session-tool-manager")` constructed **per call** inside
    a closure (TimelineToolManager.swift:71 and :82) — bypasses `.module`
  - `Logger(label: "com.positronickit.tools")` constructed **inline at the warning site**
    (Tool+OpenAI.swift:15)
- `Sources/PKShared/Utilities/Pipeline.swift:5` — `PipelineLogLevel` has only `.debug, .error`;
  `Pipeline.withLogger` (Pipeline+Logging.swift) therefore collapses every pipeline event into
  one of two swift-log levels, losing `.info`/`.notice`/`.warning` fidelity.
- No call site passes swift-log `metadata:` — all context is string-interpolated into the
  message, so logs can't be filtered/correlated by conversation, turn, tool, or provider.

## Design

Two layers: PositronicKit emits **well-labeled, metadata-rich** swift-log records (host-agnostic);
Yakamoz **bootstraps one `os.Logger` backend** that captures all of it and adds its own
app/runtime/error logs.

### PositronicKit changes

**1. Stable, consistent labels (YAK-41).**
Replace the `Bundle.main`-derived subsystem with a fixed PK subsystem and normalize all labels
to `com.positronickit.<category>` (lowercase, dot/dash, no host prefix, no redundant
`com.positronickit.` inside the `name` argument).

```swift
// Logger+Extensions.swift — before
private static var subsystem: String {
    Bundle.main.bundleIdentifier ?? "com.positronickit.core"
}
public static func module(named name: String) -> Logger {
    Logger(label: "\(subsystem).\(name)")
}

// after
public enum PKLogSubsystem { public static let value = "com.positronickit" }
public static func module(named name: String) -> Logger {
    // `name` is a bare category, e.g. "chat-engine"; never pre-prefixed.
    Logger(label: "\(PKLogSubsystem.value).\(name)")
}
```

Then fix every call site to pass a bare category (`"chat-engine"`, `"retry-policy"`,
`"context-manager"`, `"timeline-archiver"`, …) and replace the two raw `Logger(label:)`
sites with stored `Logger.module(named:)` loggers:
- `TimelineToolManager`: one stored `private let logger = Logger.module(named: "session-tool-manager")`
  instead of constructing inside the closure twice.
- `Tool+OpenAI`: a `static let` (or module-level) logger instead of inline construction at the warning.

This makes Console.app filterable by subsystem `com.positronickit` and a clean category list,
independent of which host (Monad/Shuttle/Yakamoz) loaded the package. Monad/Shuttle call sites
that rely on the old label strings must be checked (cross-repo public API change rule).

**2. Pipeline level fidelity + structured metadata (YAK-42).**
- Extend `PipelineLogLevel` to a fuller set (`trace/debug/info/notice/warning/error/critical`,
  or at minimum add `info`/`warning`) and map them through `Pipeline.withLogger` to the matching
  `Logger.Level`, so stage timing/info isn't forced to `.debug` and recoverable issues aren't
  forced to `.error`.
- Add `metadata:` at the high-value correlation points so a single failing interaction is
  filterable end-to-end:
  - chat turn stages: `conversationID`, `turnIndex`
  - tool routing/extraction: `toolName`, `toolCallID` (counts/hashes only — keep YAK-37 redaction)
  - provider/retry: `provider`, `model`, `attempt`
- Keep YAK-37 invariants: metadata values are byte counts / hashes / ids, never raw payloads,
  prompts, or secrets.

### Yakamoz changes (YAK-40)

**1. `YakamozLogHandler` (new — `Sources/YakamozCore/Logging/YakamozLogHandler.swift`).**
A `swift-log` `LogHandler` bridging to `os.Logger`:
- Caches one `os.Logger(subsystem:category:)` per label. Split the dotted label: subsystem =
  everything up to the last segment group that names the app/package (`com.positronickit` or
  `me.atkn.Yakamoz`), category = the remainder — so Console.app groups PK and Yakamoz logs
  under stable subsystems with readable categories.
- Level map: `.trace/.debug → .debug`, `.info/.notice → .info`, `.warning → .default`,
  `.error → .error`, `.critical → .fault`.
- Merges swift-log `metadata` into the formatted message; our keys may be `public`, but values
  default to redacted to honor YAK-37.

**2. Bootstrap (idempotent).**
`YakamozLogging.bootstrap()` wraps `LoggingSystem.bootstrap { YakamozLogHandler(label: $0) }`
behind a once-guard (so repeated `YakamozRuntime` construction in tests can't crash on
re-bootstrap). Called as the **first line** of `YakamozApp.init()`. This single call captures
both Yakamoz and PositronicKit output.

```swift
// YakamozApp.init() — first line
YakamozLogging.bootstrap()
```

**3. `Log` namespace.** A small enum in `YakamozCore` vending labeled subsystem loggers:
`Log.app`, `Log.runtime`, `Log.chat`, `Log.workspace`, `Log.terminal` (labels under
`me.atkn.Yakamoz.*`). Components log through these instead of nothing/`print`.

**4. Error surfacing (the debuggability win).**
- `YakamozApp.init()` `catch`: `Log.app.error("runtime init failed", metadata: ["storePath": ...])`
  using `ErrorKit.userFriendlyMessage(for:)` *before* assigning `setupError`. A failed launch
  currently leaves zero trace.
- `ChatViewModel` turn `catch`: log the error with `conversationID`/`turnIndex` metadata
  alongside the existing inline UI message, so a failed/empty turn is debuggable from Console.

## Testing

PositronicKit:
- `Logger.module(named:)` produces `com.positronickit.<name>` regardless of `Bundle.main`
  (no host prefix, no double prefix).
- `PipelineLogLevel` → `Logger.Level` mapping is exhaustive; `withLogger` preserves info/warning.
- A pipeline run emits records carrying the expected `conversationID`/`turnIndex` metadata.
- Redaction (YAK-37) holds: metadata carries no raw payloads/secrets.

Yakamoz:
- `YakamozLogHandler` level→`OSLogType` mapping and label→subsystem/category split.
- `YakamozLogging.bootstrap()` is idempotent (safe across repeated runtime construction in tests;
  tests must not globally re-bootstrap — use the once-guard / a test seam).
- `YakamozApp.init` failure path logs an error (inject a failing store URL / runtime factory).
- `ChatViewModel` turn-failure path logs with conversation/turn metadata.

Match each file's existing test framework (some Swift Testing, some XCTest); don't mix within a file.

## Acceptance criteria

- One bootstrap at launch routes **both** Yakamoz and PositronicKit swift-log output to a single
  `os.Logger` backend, filterable in Console.app by stable subsystem + category.
- PositronicKit labels are host-independent and consistently `com.positronickit.<category>`;
  no per-call `Logger(label:)` construction remains.
- Pipeline logging preserves level fidelity; key chat/tool/provider records carry correlation
  metadata.
- Previously-silent failures (app init, failed turns) leave a diagnostic trail.
- All logging is redaction-safe and consistent with YAK-37.
- PositronicKit `make verify` and Yakamoz `make verify` are green; Monad/Shuttle call sites
  updated for any changed PK label/level public surface.

## Ticket breakdown

- **YAK-40** (Yakamoz) — `os.Logger` bootstrap + `YakamozLogHandler` + `Log` namespace + error
  surfacing in `YakamozApp.init` and `ChatViewModel`. Depends on nothing (works against PK as-is;
  benefits from YAK-41/42 but not blocked by them).
- **YAK-41** (PositronicKit) — stable/consistent labels: fix `Logger.module` subsystem, normalize
  every call site, remove per-call `Logger(label:)` construction. Update Monad/Shuttle/docs.
- **YAK-42** (PositronicKit) — `PipelineLogLevel` fidelity + structured `metadata:` at chat/tool/
  provider correlation points (YAK-37-safe).

Suggested order: YAK-41 → YAK-42 (PK foundation), then/parallel YAK-40 (Yakamoz consumes the
result). YAK-40 can land first independently if desired.
