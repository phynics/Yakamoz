# YAK-22 Provider Settings and Chat Control — Design Spec

**Date:** 2026-06-29
**App:** Yakamoz
**Status:** Approved design, pending implementation plan
**Scope:** Yakamoz-only. Keep reusable provider/runtime state in `YakamozCore`; keep SwiftUI
composition in the `Yakamoz` app target.

## 1. Summary

Turn YAK-22 from vague Settings polish into an operational provider-management surface.
Yakamoz should make the active runtime target visible before the user sends a message, and
make routine endpoint/model actions available without leaving chat.

The chosen design has two surfaces:

1. **Actionable chat toolbar control**: a compact menu showing the active provider/model and
   last connection state. It supports quick model selection, refresh, favorite toggle,
   connection test, and opening Settings.
2. **Reorganized Settings window**: the full management surface for provider preset, base URL,
   API key, model selection, model-list diagnostics, health diagnostics, generation, and retry.

This preserves Yakamoz's current model-catalog work from YAK-28 while making stability,
observability, and management of multiple endpoints/models a first-class workflow.

## 2. Goals / Non-goals

### Goals

- Show the active provider endpoint/model in chat so misconfiguration is visible at the moment
  of use.
- Let users switch among ranked models from chat without opening Settings.
- Keep endpoint, API key, generation, and retry editing centralized in Settings.
- Share model-list and health-check state between Settings and the chat toolbar.
- Preserve provider/base-URL scoped favorites and recents from YAK-28.
- Surface provider failures as operational state, not as modal or blocking chat errors.

### Non-goals

- No multi-profile account manager or saved endpoint collection in this ticket.
- No per-conversation model override. The selected model remains global provider settings and
  affects the next send.
- No new PositronicKit provider abstraction unless current runtime APIs prove insufficient.
- No live provider calls in tests.

## 3. Current-state references

| Concern | Location |
| --- | --- |
| Settings UI | `Sources/Yakamoz/Views/SettingsView.swift` |
| Provider settings, validation, persistence, scoped favorites/recents | `Sources/YakamozCore/Configuration/ProviderSettings.swift` |
| Model normalization | `Sources/YakamozCore/Configuration/ModelCatalogService.swift` |
| Runtime health/model-list seams | `Sources/YakamozCore/Runtime/YakamozRuntime.swift` |
| Chat toolbar composition | `Sources/Yakamoz/Views/ChatView.swift` |
| Provider/model tests | `Tests/YakamozTests/ProviderConfigurationTests.swift` |
| Runtime tests | `Tests/YakamozTests/RuntimeCompositionTests.swift` |

## 4. User Surface

### 4.1 Chat toolbar provider control

Add a compact `ProviderControlMenu` to `ChatView`'s toolbar. It should read as an operational
target selector, not a decorative badge.

Recommended label:

- SF Symbol: provider/status icon such as `network` or a status-specific symbol.
- Text: `Preset / Model`, with the model truncated by SwiftUI as needed.
- Help/accessibility text includes the full base URL and last health state.

Menu content:

- Header rows: provider preset, base URL host, current model, last health result.
- Suggested models: ranked models from existing provider/base-URL scoped favorites, recents,
  provider response, and current manual model.
- `Refresh Models`
- `Favorite Current Model` / `Unfavorite Current Model`
- `Test Connection`
- `Open Settings`

The menu must stay useful when the model-list API fails: keep showing the current model and
manual fallback message, and leave Settings as the place to edit the raw model id.

### 4.2 Settings layout

Reorganize `SettingsView` into clearer groups:

1. **Active Target**
   - Preset picker.
   - Base URL field with inline validation.
   - Current model.
   - Suggested model picker when available.
   - Manual model text field retained as the escape hatch.
2. **Credentials**
   - API key secure field.
   - Explicit Apply button.
   - Plaintext `UserDefaults` storage note, consistent with YAK-14 and README.
3. **Diagnostics**
   - Health check button and last result.
   - Model-list refresh state and error message.
   - Active endpoint/model summary.
4. **Generation**
   - Existing generation controls.
5. **Retry**
   - Existing retry controls.

Settings remains the only place where the user edits provider preset, base URL, API key,
generation parameters, and retry settings.

## 5. Architecture

Introduce a small main-actor provider status boundary in `YakamozCore`, tentatively
`ProviderStatusViewModel`.

Responsibilities:

- Own a current `ProviderSettingsSnapshot` for display.
- Load and expose available model IDs.
- Expose ranked models via existing `ProviderSettings.rankedModels(from:)`.
- Track model-list loading/error state.
- Track last health-check status and timestamp.
- Select a model through `ProviderSettings.applyModelSelection(_:)`.
- Toggle current-model favorite through `ProviderSettings.toggleFavoriteModel(_:)`.
- Refresh models through `YakamozRuntime.fetchAvailableModels()`.
- Test connection through `YakamozRuntime.appHealthCheck()`.
- Clear stale health/model-list state after target-affecting changes.

`SettingsView` and `ProviderControlMenu` should consume the same boundary shape. If lifecycle
ownership is simpler as one instance per surface, the behavior should still be centralized in
the `YakamozCore` type rather than duplicated in SwiftUI views.

The `Yakamoz` app target must continue importing only SwiftUI/SwiftData/YakamozCore. Any type
that mirrors provider health for the app target should stay in `YakamozCore`, following the
existing `AppHealthStatus` boundary.

## 6. Data Flow

1. `ProviderStatusViewModel` initializes from `ProviderSettings.snapshot`.
2. Opening Settings or the chat menu triggers a model refresh if the list is empty or stale.
3. `refreshModels()` validates the active base URL, calls `runtime.fetchAvailableModels()`,
   and stores either normalized model IDs or a non-blocking error.
4. Selecting a model calls `settings.applyModelSelection(modelID)`, records recency, persists
   settings, refreshes the snapshot, and updates both surfaces.
5. Testing the connection calls `runtime.appHealthCheck()` and records the result plus a
   timestamp.
6. Changing preset/base URL/API key in Settings clears stale diagnostics and refreshes model
   availability after the change is applied.

In-flight turns continue using the configuration captured when the turn began. The selected
model affects the next send, matching the current runtime composition model.

## 7. Error Handling and Observability

- Invalid base URL: inline Settings validation; disable or fail `Refresh Models` and
  `Test Connection` with a clear message.
- Missing API key: Settings validation keeps current behavior; Ollama remains allowed to use a
  blank key.
- Model-list failure: non-blocking state such as "Model list unavailable. Manual entry remains
  available." Keep current model visible.
- Health failure: map to `.down` and show it in both Settings and chat menu. Do not throw into
  the chat transcript.
- Stale diagnostics: when preset/base URL/API key changes, visually mark or clear the previous
  health result so the user does not mistake it for the new endpoint's status.

## 8. Testing

Add focused tests around behavior, not layout snapshots:

- `ProviderStatusViewModel` refresh success stores ranked models and clears previous errors.
- Refresh failure preserves current model visibility and records a non-blocking error.
- Health check success/failure records `AppHealthStatus` and timestamp.
- Model selection delegates to `ProviderSettings.applyModelSelection(_:)`, persists, and records
  recency.
- Favorite toggle delegates to provider/base-URL scoped favorites.
- Target changes clear stale diagnostics.
- Existing `ProviderConfigurationTests` continue covering scoped favorites/recents,
  normalization, validation, and secret-account behavior.
- `RuntimeCompositionTests` keep using injected fake LLM services; no live endpoint calls.

SwiftUI tests should be limited to existing project patterns. The important regression surface
is the shared status boundary and action wiring.

## 9. Implementation Notes

- Prefer extracting small SwiftUI subviews from `SettingsView` instead of growing the file
  further.
- Avoid introducing a new persisted model unless the implementation needs cross-launch
  diagnostic history. The last health result can be in-memory.
- Truncate long model IDs in the toolbar, but expose the full value in menu content and
  accessibility/help text.
- Keep manual model entry as the escape hatch for custom endpoints and provider failures.
- Do not expand scope into saved provider profiles. That can be a later ticket after YAK-22
  proves the operational shape.

