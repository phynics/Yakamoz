# YAK-14 — Replace Keychain secret storage with UserDefaults

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

Provider API keys are stored via `KeychainStore` (conforming to `SecretStoring`). The
request is to drop the Keychain dependency and store secrets in `UserDefaults` instead.

> ⚠️ **Security note.** UserDefaults is plaintext: keys land in
> `~/Library/Preferences/<bundle-id>.plist`, readable by any process running as the user
> and included in unencrypted backups. This is an explicit, accepted downgrade for a
> local showcase app. Document it in the README so it isn't mistaken for secure storage.

## Proposed approach
- Add a `UserDefaultsSecretStore` conforming to the existing `SecretStoring` protocol
  (`read`/`write`/account-keyed), backed by a named `UserDefaults` suite (suite name tied
  to the bundle id — coordinate with [YAK-13](YAK-13-bundle-identifier-rename.md)).
- Swap the production wiring in `YakamozApp.init()` from `KeychainStore()` to the new
  store. Keep `SecretStoring` as the seam so tests keep using `FakeSecretStore`.
- Provide a one-time best-effort import of any existing Keychain value into UserDefaults
  on first launch (optional — decide whether prior Keychain keys should carry over).
- Delete `KeychainStore` (and its Security framework usage) once nothing references it.
- Update the README's "Keychain behavior" section.

## Acceptance criteria
- API keys persist across relaunch via UserDefaults; per-provider account separation
  preserved (the existing multi-provider key tests still pass).
- No remaining Keychain/Security references.
- README documents the plaintext-storage tradeoff.
- `make verify` green.

## Pointers
- `Sources/YakamozCore/Configuration/KeychainStore.swift` (`SecretStoring`, `KeychainStore`)
- `Sources/Yakamoz/YakamozApp.swift` (`secrets = KeychainStore()`)
- `Sources/YakamozCore/Configuration/ProviderSettings.swift` (account-key naming, `storedAPIKey`)
- `README.md` (Keychain behavior section)
