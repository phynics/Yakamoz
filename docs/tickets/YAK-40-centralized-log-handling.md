# YAK-40 - Centralized log handling (os.Logger bootstrap + error surfacing)

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Spec:** `docs/superpowers/specs/2026-06-30-logging-debuggability-design.md`
- **Related:** YAK-41, YAK-42 (PositronicKit side); YAK-37 (redaction)

## Problem

Yakamoz never configures logging, so a running session is undebuggable:

- No `LoggingSystem.bootstrap` — PositronicKit's swift-log output (chat pipeline, providers,
  retries, tool routing) goes to the default unconfigured handler and effectively vanishes.
- `swift-log` is on the classpath via PositronicKit and Yakamoz already `import Logging`, but
  the only use is threading an optional `promptAssemblyLogger` that every call site passes as
  `nil` (`Sources/YakamozCore/Chat/ChatViewModel.swift:220`,
  `Sources/YakamozCore/Runtime/YakamozRuntime.swift:291/304/448`).
- `YakamozApp.init()`'s `catch` stuffs `error.localizedDescription` into a UI string
  (`setupError`) and logs nothing — a failed launch leaves zero trace.
- `ChatViewModel` catches turn errors, shows an inline message, and logs nothing.

Goal: developer-grade observability via Apple unified logging (Console.app). Out of scope:
file sink, Settings verbose toggle, prompt-assembly verbose logs (seam stays wired but `nil`).

## Affected code

- `Sources/Yakamoz/YakamozApp.swift` — `@main` `init()`: bootstrap call + error logging in `catch`.
- New: `Sources/YakamozCore/Logging/YakamozLogHandler.swift` and `YakamozLogging` bootstrap.
- New: `Sources/YakamozCore/Logging/Log.swift` — `Log.app/.runtime/.chat/.workspace/.terminal`.
- `Sources/YakamozCore/Chat/ChatViewModel.swift` — log in the turn `catch` with metadata.

## Before / after

### Before

```swift
// YakamozApp.init() — no logging setup; failure swallowed into UI string
} catch {
    modelContainer = nil
    setupError = "\(error.localizedDescription) (store path: \(resolvedStoreDescription))"
}
```

### After

```swift
init() {
    YakamozLogging.bootstrap()   // first line; idempotent, captures Yakamoz + PositronicKit
    ...
    } catch {
        modelContainer = nil
        Log.app.error("runtime init failed", metadata: ["storePath": "\(resolvedStoreDescription)"])
        setupError = "\(ErrorKit.userFriendlyMessage(for: error)) (store path: \(resolvedStoreDescription))"
    }
}
```

`YakamozLogHandler` bridges swift-log → `os.Logger`: caches one `os.Logger(subsystem:category:)`
per label; level map `.trace/.debug→.debug`, `.info/.notice→.info`, `.warning→.default`,
`.error→.error`, `.critical→.fault`; merges metadata into the message (values redacted per YAK-37).

## Tests

- `YakamozLogHandler` level→`OSLogType` mapping and label→subsystem/category split.
- `YakamozLogging.bootstrap()` is idempotent (safe across repeated runtime construction in tests;
  do not globally re-bootstrap — use the once-guard / test seam).
- `YakamozApp.init` failure path logs an error (inject failing store URL / runtime factory).
- `ChatViewModel` turn-failure path logs with `conversationID`/`turnIndex` metadata.
- Match each file's existing framework; don't mix within a file.

## Acceptance criteria

- One bootstrap at launch routes both Yakamoz and PositronicKit swift-log output to a single
  `os.Logger` backend, filterable in Console.app by stable subsystem + category.
- Components log through labeled `Log.*` loggers instead of `print` / silent swallowing.
- Previously-silent failures (app init, failed turns) leave a diagnostic trail.
- Logging is redaction-safe and consistent with YAK-37.
- Yakamoz `make verify` is green.
