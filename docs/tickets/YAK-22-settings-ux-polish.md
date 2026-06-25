# YAK-22 — Settings UX polish

- **Status:** Open
- **Priority:** Low
- **Repos:** Yakamoz
- **Surfaced by:** field feedback (2026-06-25)

## Problem

The Settings screen "works for now" but is rough and could be improved. This is a
catch-all placeholder to revisit once the higher-priority items land; it needs concrete
direction before implementation.

## Possible directions (to refine)
- Clearer provider/preset layout; show the active endpoint + model prominently.
- Inline validation + a more legible health-check result.
- Group secret entry (and note the storage model — see
  [YAK-14](YAK-14-userdefaults-secret-storage.md)) distinctly from model/provider config.
- Consider whether per-provider keys and model selection are discoverable.

## Acceptance criteria
- TBD — define specific improvements before picking this up (do a quick brainstorm pass).

## Pointers
- `Sources/Yakamoz/Views/SettingsView.swift`
- `Sources/YakamozCore/Configuration/ProviderSettings.swift`
