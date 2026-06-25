# YAK-13 — Rename bundle identifier to me.atkn.Yakamoz

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The bundle identifier is currently `com.atakandulker.Yakamoz`. Change it to
`me.atkn.Yakamoz`. The id is referenced in more than one place and a naive
find/replace would orphan data:

- `project.yml`: `PRODUCT_BUNDLE_IDENTIFIER` for the `Yakamoz`, `YakamozCore`, and
  `YakamozTests` targets (currently `com.atakandulker.{Yakamoz,YakamozCore,YakamozTests}`).
- `Sources/Yakamoz/YakamozApp.swift`: `storeBundleIdentifier = "com.atakandulker.Yakamoz"`
  (YAK-7) — the SwiftData store lives at
  `~/Library/Application Support/com.atakandulker.Yakamoz/Yakamoz.store`. Changing the
  id changes that directory, so an existing store must be migrated again.
- Secret storage is keyed by app identity (Keychain service today; UserDefaults suite if
  YAK-14 lands first) — coordinate so saved keys aren't lost.

## Proposed approach
- Update all three `PRODUCT_BUNDLE_IDENTIFIER`s in `project.yml`.
- Update `storeBundleIdentifier`. Extend `migrateLegacyStoreIfNeeded` (or add a sibling)
  so an existing store under the old `com.atakandulker.Yakamoz/` directory is relocated
  to the new `me.atkn.Yakamoz/` directory once (guarded, never clobbers — same shape as
  the existing legacy migration).
- Do this **together with YAK-14** if possible, so secret-store keying changes once.

## Acceptance criteria
- App builds and runs under `me.atkn.Yakamoz`.
- An install that had data under the old id keeps its conversations and store after the
  rename (one-time migration); a fresh install is unaffected.
- `make verify` green.

## Pointers
- `project.yml` (three `PRODUCT_BUNDLE_IDENTIFIER` lines)
- `Sources/Yakamoz/YakamozApp.swift` (`storeBundleIdentifier`, `resolveStoreURL`, `migrateLegacyStoreIfNeeded`)
- [YAK-14](YAK-14-userdefaults-secret-storage.md) (coordinate secret-store keying)
