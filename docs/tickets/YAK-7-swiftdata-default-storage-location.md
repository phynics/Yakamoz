# YAK-7 — Make SwiftData's storage location explicit

- **Status:** Open
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** post-CP11 follow-up request

## Problem

`YakamozApp.init()` builds its `ModelConfiguration` with no explicit `url:`:

```swift
let schema = Schema(YakamozSchema.models)
let configuration = ModelConfiguration(schema: schema)
let container = try ModelContainer(for: schema, configurations: configuration)
```

This works (SwiftData falls back to its own default `Application Support/<bundle-id>/default.store`
location), but the location is implicit — nothing in the codebase documents or
confirms where the database file actually lands, and a future change to the
bundle identifier, sandboxing entitlements, or SwiftData's own defaults could
silently relocate or fragment user data with no migration path.

## Proposed approach

Make the location explicit and intentional rather than relying on the implicit
default:

- Compute the standard per-app Application Support directory via
  `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`,
  append the bundle identifier (`com.atakandulker.Yakamoz`) and a stable
  filename (e.g. `Yakamoz.store`), and create the directory if missing.
- Pass that resolved `url:` into `ModelConfiguration(schema:url:)` so the path
  is explicit, logged (e.g. on a setup failure, include the path in
  `setupError` for diagnosability), and stable across app/bundle-id changes.
- Document the resolved path in `Yakamoz/README.md`.

## Acceptance criteria
- `ModelConfiguration` is constructed with an explicit, computed `url:`.
- The resolved path is documented in the README.
- Existing tests (which use in-memory or temp-directory containers) are unaffected.
- No data migration needed if the explicit path matches SwiftData's prior
  implicit default (verify on a clean run before/after).

## Pointers
- `Sources/Yakamoz/YakamozApp.swift:57-60`
