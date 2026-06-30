# YAK-22 — Settings UX polish

- **Status:** Open
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The Settings screen "works for now" but is rough and could be improved. After YAK-28 added
model suggestions, favorites, recents, and manual fallback, the remaining Settings problem is
less about cosmetics and more about making the active provider endpoint/model stable,
observable, and manageable during normal chat use.

Design direction is captured in
[`../superpowers/specs/2026-06-29-yak-22-provider-settings-design.md`](../superpowers/specs/2026-06-29-yak-22-provider-settings-design.md):
combine a reorganized Settings window with an actionable chat toolbar provider control.

## Required direction

- Add a compact, actionable chat toolbar control showing the active provider/model and last
  connection state.
- Let that control switch among ranked suggested models, refresh the model list,
  favorite/unfavorite the current model, test the connection, and open Settings.
- Reorganize Settings around Active Target, Credentials, Diagnostics, Generation, and Retry.
- Keep preset/base URL/API key/generation/retry editing in Settings; the chat control is for
  visibility and routine model/status actions.
- Preserve manual model entry as the fallback for custom endpoints and provider failures.

## Acceptance criteria

- Chat shows the active provider/model/status in an actionable toolbar menu.
- A user can switch to a ranked model from chat without typing the model id manually.
- Model refresh and health check state is shared through a YakamozCore boundary rather than
  duplicated independently in Settings and Chat SwiftUI views.
- Settings clearly separates active endpoint/model configuration, credentials, diagnostics,
  generation, and retry controls.
- Invalid base URLs, missing API keys, model-list failures, and failed health checks surface
  inline without blocking chat or removing the manual model fallback.
- Provider/base-URL scoped favorites and recents from YAK-28 continue to work.
- Focused tests cover provider-status refresh, health, model selection, favorite toggle,
  stale diagnostic clearing, and failure fallback without live network calls.

## Pointers
- `Sources/Yakamoz/Views/SettingsView.swift`
- `Sources/YakamozCore/Configuration/ProviderSettings.swift`
- `Sources/YakamozCore/Configuration/ModelCatalogService.swift`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift`
- `Sources/Yakamoz/Views/ChatView.swift`
