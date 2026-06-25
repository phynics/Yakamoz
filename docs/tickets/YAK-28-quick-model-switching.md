# YAK-28 — Quick model switching with favorites and recency

- **Status:** Open
- **Priority:** Medium
- **Repos:** Yakamoz (+ PositronicKit if provider model-list APIs are missing)
- **Surfaced by:** product follow-up (2026-06-25)

## Problem

Yakamoz currently exposes the active model as a freeform text field in Settings. That is
useful as an escape hatch, but it makes switching between common models slower than it
should be. Users need a quick way to pick from the provider's available models, with the
models they actually use kept near the top.

## Task

- Add a quick model switcher that can update `ProviderSettings.model` without requiring
  manual text entry.
- Feed the switcher from the active provider's model-list API when available.
- Rank the list with pinned favorites first, then recently used models, then the rest of
  the provider response.
- Keep freeform model entry as a fallback for custom endpoints or provider API failures.
- Persist favorites and last-used metadata per provider/base URL so OpenAI, OpenRouter,
  Ollama, and custom endpoints do not pollute each other's model suggestions.

## Design directions to evaluate

1. **Settings-only picker first**
   - Replace or augment the Settings model text field with a searchable picker.
   - Lower implementation risk because `SettingsView` already owns provider preset,
     base URL, API key staging, and `ProviderSettings.model`.
   - Less convenient during active chat.

2. **Chat-toolbar quick switcher**
   - Add a compact model menu near the composer or conversation toolbar.
   - Better day-to-day ergonomics: switch models before the next send without opening
     Settings.
   - Needs care around rebuild timing so an in-flight turn continues using the model it
     started with while the next turn uses the new selection.

3. **Shared model-picker component**
   - Build a reusable picker and use it in both Settings and chat.
   - Best long-term shape if scope allows, but keep the first pass small enough to land
     without turning Settings polish into a larger redesign.

## Provider API considerations

- Prefer a provider-agnostic `ModelCatalog`/`ModelListingService` boundary in
  YakamozCore or PositronicKit rather than putting HTTP logic directly in SwiftUI views.
- OpenAI-compatible providers generally expose a `/models` endpoint, but payload details,
  pagination, auth requirements, and model metadata vary. OpenRouter and Ollama may need
  provider-specific normalization.
- Cache successful model-list responses briefly to avoid network calls every time a menu
  opens; expose a manual refresh affordance.
- Handle failures quietly: keep the current model, show a small error/empty state, and
  preserve manual entry.

## Acceptance criteria

- A user can switch the active model from a list without typing the model id manually.
- Favorites can be toggled and are shown before other models for the same provider/base
  URL.
- Recently used models are recorded when selected and are ranked ahead of never-used
  models after favorites.
- The current model remains visible and selectable even if the provider model-list API
  fails or does not include it.
- Switching models persists through `ProviderSettings.persist()` and affects the next
  chat turn, not an already-running one.
- Provider API failures do not break Settings or chat; manual model entry still works.
- Add focused tests for model ranking, persistence keys, and failure fallback behavior.
- `make verify` is green in Yakamoz; PositronicKit tests/build are green if shared
  provider API support is added there.

## Pointers

- `Sources/Yakamoz/Views/SettingsView.swift`
- `Sources/Yakamoz/Views/ChatView.swift`
- `Sources/YakamozCore/Configuration/ProviderSettings.swift`
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift`
- `Tests/YakamozTests/RuntimeCompositionTests.swift`
- `Tests/YakamozTests/ConversationCoordinatorTests.swift`
