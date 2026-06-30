# YAK-22 Provider Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an actionable provider/model control to chat and reorganize Settings around stable endpoint/model management and diagnostics.

**Architecture:** Add a `@MainActor @Observable ProviderStatusViewModel` in `YakamozCore` as the shared behavior boundary for model refresh, health checks, model selection, favorite toggling, and stale diagnostic clearing. Keep SwiftUI views thin: `SettingsView` and a new `ProviderControlMenu` consume that boundary, while `ProviderSettings` remains the persistence source and `YakamozRuntime` remains the provider async boundary.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Observation, Swift Testing, XcodeGen via `make`.

## Global Constraints

- Yakamoz is a local, non-sandboxed, single-user macOS SwiftUI showcase app.
- The app target (`Sources/Yakamoz`) imports only SwiftUI/SwiftData/`YakamozCore`, never PositronicKit/PKShared.
- Commands run from `Yakamoz/`; use `make generate`, `make build`, `make test`, and `make verify`, not bare `swift build`.
- Tests never call live model endpoints; use fakes or injected runtime seams.
- Preserve API keys as explicit-apply secrets through `SecretStoring`; do not write them through `ProviderSettings.persist()`.
- Preserve provider/base-URL scoped favorites and recents from YAK-28.
- The selected model remains global provider settings and affects the next send; do not add per-conversation model overrides.

---

## File Structure

- Create `Sources/YakamozCore/Configuration/ProviderStatusViewModel.swift`
  - Owns shared provider operational state and actions.
  - Depends on `ProviderSettings` and a small async client protocol.
- Create `Tests/YakamozTests/ProviderStatusViewModelTests.swift`
  - Covers refresh success/failure, health, model selection, favorite toggle, and stale diagnostics.
- Create `Sources/Yakamoz/Views/ProviderControlMenu.swift`
  - Chat toolbar menu over `ProviderStatusViewModel`.
- Modify `Sources/Yakamoz/Views/SettingsView.swift`
  - Replace local model/health state with `ProviderStatusViewModel`.
  - Split sections into Active Target, Credentials, Diagnostics, Generation, Retry.
- Modify `Sources/Yakamoz/Views/ChatView.swift`
  - Add provider settings environment and install `ProviderControlMenu` in the toolbar.
- Modify `docs/tickets/YAK-22-settings-ux-polish.md`
  - Mark done after implementation and summarize resolution.
- Modify `docs/tickets/README.md`
  - Mark YAK-22 done and remove it from the open summary.

---

### Task 1: Add ProviderStatusViewModel Core Boundary

**Files:**
- Create: `Sources/YakamozCore/Configuration/ProviderStatusViewModel.swift`
- Create: `Tests/YakamozTests/ProviderStatusViewModelTests.swift`

**Interfaces:**
- Consumes: `ProviderSettings`, `ProviderSettingsSnapshot`, `AppHealthStatus`.
- Produces:
  - `public protocol ProviderStatusRuntime: Sendable`
  - `extension YakamozRuntime: ProviderStatusRuntime`
  - `@MainActor @Observable public final class ProviderStatusViewModel`
  - `public enum ProviderStatusError: LocalizedError, Equatable`

- [ ] **Step 1: Write failing view-model tests**

Create `Tests/YakamozTests/ProviderStatusViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import YakamozCore

@MainActor
@Suite("ProviderStatusViewModel")
struct ProviderStatusViewModelTests {
    private final class FakeProviderRuntime: ProviderStatusRuntime, @unchecked Sendable {
        var modelsResult: Result<[String], Error> = .success(["gpt-4.1", "gpt-4o-mini"])
        var healthStatus: AppHealthStatus = .ok
        private(set) var modelFetchCount = 0
        private(set) var healthCheckCount = 0

        func fetchAvailableModels() async throws -> [String] {
            modelFetchCount += 1
            return try modelsResult.get()
        }

        func appHealthCheck() async -> AppHealthStatus {
            healthCheckCount += 1
            return healthStatus
        }
    }

    private struct ModelListFailure: LocalizedError {
        var errorDescription: String? { "model list failed" }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ProviderStatusViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("refreshModels stores ranked models and clears previous errors")
    func refreshModelsStoresRankedModels() async {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.model = "manual-current"
        settings.toggleFavoriteModel("gpt-4.1")
        settings.recordRecentModel("gpt-4o-mini")
        let runtime = FakeProviderRuntime()
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)
        viewModel.modelLoadError = "old error"

        await viewModel.refreshModels()

        #expect(runtime.modelFetchCount == 1)
        #expect(viewModel.rankedModels == ["gpt-4.1", "gpt-4o-mini", "manual-current"])
        #expect(viewModel.modelLoadError == nil)
        #expect(viewModel.isLoadingModels == false)
    }

    @Test("refresh failure preserves current model visibility")
    func refreshFailurePreservesCurrentModel() async {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.model = "manual-current"
        let runtime = FakeProviderRuntime()
        runtime.modelsResult = .failure(ModelListFailure())
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)

        await viewModel.refreshModels()

        #expect(viewModel.rankedModels == ["manual-current"])
        #expect(viewModel.modelLoadError == "Model list unavailable. Manual entry remains available.")
        #expect(viewModel.isLoadingModels == false)
    }

    @Test("testConnection records health and timestamp")
    func testConnectionRecordsHealth() async {
        let settings = ProviderSettings(defaults: makeDefaults())
        let runtime = FakeProviderRuntime()
        runtime.healthStatus = .degraded
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)

        await viewModel.testConnection()

        #expect(runtime.healthCheckCount == 1)
        #expect(viewModel.healthStatus == .degraded)
        #expect(viewModel.lastHealthCheckedAt != nil)
        #expect(viewModel.isCheckingHealth == false)
    }

    @Test("selectModel persists and records recency")
    func selectModelPersistsAndRecordsRecency() {
        let defaults = makeDefaults()
        let settings = ProviderSettings(defaults: defaults)
        let runtime = FakeProviderRuntime()
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)

        viewModel.selectModel("gpt-4.1")

        #expect(settings.model == "gpt-4.1")
        #expect(settings.recentModels() == ["gpt-4.1"])
        #expect(ProviderSettings(defaults: defaults).model == "gpt-4.1")
    }

    @Test("toggleFavoriteCurrentModel delegates to scoped favorites")
    func toggleFavoriteCurrentModel() {
        let settings = ProviderSettings(defaults: makeDefaults())
        settings.model = "gpt-4.1"
        let runtime = FakeProviderRuntime()
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)

        viewModel.toggleFavoriteCurrentModel()

        #expect(settings.favoriteModels() == ["gpt-4.1"])
        #expect(viewModel.isCurrentModelFavorite)
    }

    @Test("target changes clear stale diagnostics")
    func targetChangesClearStaleDiagnostics() async throws {
        let settings = ProviderSettings(defaults: makeDefaults())
        let runtime = FakeProviderRuntime()
        let viewModel = ProviderStatusViewModel(settings: settings, runtime: runtime)
        await viewModel.testConnection()
        viewModel.modelLoadError = "old error"

        try viewModel.updateBaseURL("https://example.invalid/v1")

        #expect(viewModel.healthStatus == nil)
        #expect(viewModel.lastHealthCheckedAt == nil)
        #expect(viewModel.modelLoadError == nil)
        #expect(settings.baseURL.absoluteString == "https://example.invalid/v1")
    }
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
make test TEST_FILTER=ProviderStatusViewModelTests
```

Expected: FAIL because `ProviderStatusRuntime` and `ProviderStatusViewModel` do not exist.

- [ ] **Step 3: Implement the view model**

Create `Sources/YakamozCore/Configuration/ProviderStatusViewModel.swift`:

```swift
import Foundation
import Observation

public protocol ProviderStatusRuntime: Sendable {
    func fetchAvailableModels() async throws -> [String]
    func appHealthCheck() async -> AppHealthStatus
}

extension YakamozRuntime: ProviderStatusRuntime {}

public enum ProviderStatusError: LocalizedError, Equatable {
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            "Invalid provider base URL: \(value)"
        }
    }
}

@MainActor
@Observable
public final class ProviderStatusViewModel {
    public private(set) var availableModels: [String] = []
    public var modelLoadError: String?
    public private(set) var healthStatus: AppHealthStatus?
    public private(set) var lastHealthCheckedAt: Date?
    public private(set) var isLoadingModels = false
    public private(set) var isCheckingHealth = false

    private let settings: ProviderSettings
    private let runtime: any ProviderStatusRuntime
    private let clock: () -> Date

    public init(
        settings: ProviderSettings,
        runtime: any ProviderStatusRuntime,
        clock: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.runtime = runtime
        self.clock = clock
    }

    public var snapshot: ProviderSettingsSnapshot {
        settings.snapshot
    }

    public var currentModel: String {
        settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var rankedModels: [String] {
        settings.rankedModels(from: availableModels)
    }

    public var isCurrentModelFavorite: Bool {
        let model = currentModel
        return !model.isEmpty && settings.isFavoriteModel(model)
    }

    public var providerLabel: String {
        switch settings.preset {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }

    public var endpointHostLabel: String {
        settings.baseURL.host ?? settings.baseURL.absoluteString
    }

    public var toolbarTitle: String {
        let model = currentModel.isEmpty ? "No model" : currentModel
        return "\(providerLabel) / \(model)"
    }

    public func refreshModels() async {
        do {
            try settings.validateBaseURL()
        } catch {
            availableModels = []
            modelLoadError = error.localizedDescription
            return
        }

        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            availableModels = try await runtime.fetchAvailableModels()
            modelLoadError = nil
        } catch {
            availableModels = []
            modelLoadError = "Model list unavailable. Manual entry remains available."
        }
    }

    public func testConnection() async {
        do {
            try settings.validateBaseURL()
        } catch {
            healthStatus = .down
            lastHealthCheckedAt = clock()
            modelLoadError = error.localizedDescription
            return
        }

        isCheckingHealth = true
        healthStatus = await runtime.appHealthCheck()
        lastHealthCheckedAt = clock()
        isCheckingHealth = false
    }

    public func selectModel(_ modelID: String) {
        settings.applyModelSelection(modelID)
    }

    public func updateManualModel(_ modelID: String) {
        settings.model = modelID
        settings.persist()
    }

    public func toggleFavoriteCurrentModel() {
        let model = currentModel
        guard !model.isEmpty else { return }
        settings.toggleFavoriteModel(model)
    }

    public func applyPreset(_ preset: ProviderPreset) {
        settings.applyPreset(preset)
        settings.persist()
        clearDiagnosticsForTargetChange()
    }

    public func updateBaseURL(_ value: String) throws {
        guard let url = URL(string: value) else {
            throw ProviderStatusError.invalidBaseURL(value)
        }
        settings.baseURL = url
        try settings.validateBaseURL()
        settings.persist()
        clearDiagnosticsForTargetChange()
    }

    public func clearDiagnosticsForTargetChange() {
        availableModels = []
        modelLoadError = nil
        healthStatus = nil
        lastHealthCheckedAt = nil
    }
}
```

- [ ] **Step 4: Run focused tests to verify they pass**

Run:

```bash
make test TEST_FILTER=ProviderStatusViewModelTests
```

Expected: PASS with non-zero tests executed.

- [ ] **Step 5: Commit**

Do not commit yet if executing the whole YAK-22 ticket inline and the user requested one final
cleanup commit. Otherwise:

```bash
git add Sources/YakamozCore/Configuration/ProviderStatusViewModel.swift Tests/YakamozTests/ProviderStatusViewModelTests.swift
git commit -m "feat: add provider status view model"
```

### Task 2: Refactor Settings Around ProviderStatusViewModel

**Files:**
- Modify: `Sources/Yakamoz/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ProviderStatusViewModel` from Task 1.
- Produces: Settings sections Active Target, Credentials, Diagnostics, Generation, Retry.

- [ ] **Step 1: Replace local provider operational state with a status view model**

In `SettingsView`, replace:

```swift
@State private var availableModels: [String] = []
@State private var healthStatus: AppHealthStatus?
@State private var isCheckingHealth = false
@State private var isLoadingModels = false
@State private var modelLoadError: String?
```

with:

```swift
@State private var providerStatus: ProviderStatusViewModel
```

and add an initializer:

```swift
init(runtime: YakamozRuntime, settings: ProviderSettings, secrets: any SecretStoring) {
    self.runtime = runtime
    self.settings = settings
    self.secrets = secrets
    _providerStatus = State(initialValue: ProviderStatusViewModel(settings: settings, runtime: runtime))
}
```

- [ ] **Step 2: Split the form into named sections**

Replace the top-level `Form` body with calls to focused computed views:

```swift
Form {
    activeTargetSection
    credentialsSection
    diagnosticsSection
    generationSection
    retrySection
}
.formStyle(.grouped)
.frame(minWidth: 480, minHeight: 520)
.task {
    loadAPIKeyForSelectedPreset()
    await providerStatus.refreshModels()
}
```

- [ ] **Step 3: Implement Active Target section**

Add:

```swift
private var activeTargetSection: some View {
    Section("Active Target") {
        Picker("Preset", selection: presetBinding) {
            ForEach(ProviderPreset.allCases, id: \.self) { preset in
                Text(presetLabel(preset)).tag(preset)
            }
        }

        TextField("Base URL", text: baseURLBinding)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)

        if providerStatus.isLoadingModels {
            ProgressView("Loading models...")
                .controlSize(.small)
        } else if !providerStatus.rankedModels.isEmpty {
            Picker("Suggested Model", selection: suggestedModelBinding) {
                ForEach(providerStatus.rankedModels, id: \.self) { modelID in
                    Text(modelID).tag(modelID)
                }
            }
        }

        TextField("Model", text: manualModelBinding)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }
}
```

- [ ] **Step 4: Implement Credentials section**

Add:

```swift
private var credentialsSection: some View {
    Section("Credentials") {
        SecureField("API Key", text: $apiKeyDraft)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("Apply API Key") {
                applyAPIKey()
            }
            .accessibilityLabel("Apply API Key")

            if let applyError {
                Text(applyError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }

        Text("API keys are stored in the app's UserDefaults secrets suite for this local showcase app, not in Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Implement Diagnostics section**

Add:

```swift
private var diagnosticsSection: some View {
    Section("Diagnostics") {
        LabeledContent("Provider", value: providerStatus.providerLabel)
        LabeledContent("Endpoint", value: providerStatus.endpointHostLabel)
        LabeledContent("Model", value: providerStatus.currentModel.isEmpty ? "Not set" : providerStatus.currentModel)

        HStack {
            Button("Refresh Models") {
                Task { await providerStatus.refreshModels() }
            }
            .disabled(providerStatus.isLoadingModels)

            if !providerStatus.currentModel.isEmpty {
                Button(providerStatus.isCurrentModelFavorite ? "Unfavorite Current Model" : "Favorite Current Model") {
                    providerStatus.toggleFavoriteCurrentModel()
                }
            }
        }

        if let modelLoadError = providerStatus.modelLoadError {
            Text(modelLoadError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            Button("Test Connection") {
                Task { await providerStatus.testConnection() }
            }
            .disabled(providerStatus.isCheckingHealth)
            .accessibilityLabel("Test Connection")

            if providerStatus.isCheckingHealth {
                ProgressView()
                    .controlSize(.small)
            } else if let healthStatus = providerStatus.healthStatus {
                HealthStatusBadge(status: healthStatus)
            }
        }
    }
}
```

- [ ] **Step 6: Move existing Generation and Retry controls into computed sections**

Add:

```swift
private var generationSection: some View {
    Section("Generation") {
        OptionalDoubleField(label: "Temperature", value: $settings.temperature)
            .onChange(of: settings.temperature) { _, _ in settings.persist() }
        OptionalIntField(label: "Max Output Tokens", value: $settings.maxTokens)
            .onChange(of: settings.maxTokens) { _, _ in settings.persist() }
    }
}

private var retrySection: some View {
    Section("Retry") {
        Stepper("Max Retries: \(settings.maxRetries)", value: $settings.maxRetries, in: 0 ... 10)
            .onChange(of: settings.maxRetries) { _, _ in settings.persist() }

        HStack {
            Text("Timeout (seconds)")
            Spacer()
            TextField("Timeout", value: $settings.timeoutInterval, format: .number)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .accessibilityLabel("Timeout in seconds")
                .onChange(of: settings.timeoutInterval) { _, _ in settings.persist() }
        }
    }
}
```

- [ ] **Step 7: Update bindings and actions**

Use these bindings:

```swift
private var suggestedModelBinding: Binding<String> {
    Binding(
        get: { settings.model },
        set: { newValue in providerStatus.selectModel(newValue) }
    )
}

private var manualModelBinding: Binding<String> {
    Binding(
        get: { settings.model },
        set: { providerStatus.updateManualModel($0) }
    )
}

private var presetBinding: Binding<ProviderPreset> {
    Binding(
        get: { settings.preset },
        set: { newValue in
            providerStatus.applyPreset(newValue)
            loadAPIKeyForSelectedPreset()
            Task { await providerStatus.refreshModels() }
        }
    )
}

private var baseURLBinding: Binding<String> {
    Binding(
        get: { settings.baseURL.absoluteString },
        set: { newValue in
            do {
                try providerStatus.updateBaseURL(newValue)
                Task { await providerStatus.refreshModels() }
            } catch {
                providerStatus.modelLoadError = error.localizedDescription
            }
        }
    )
}
```

In `applyAPIKey()`, after successful secret write, replace the old refresh call with:

```swift
providerStatus.clearDiagnosticsForTargetChange()
Task { await providerStatus.refreshModels() }
```

In `loadAPIKeyForSelectedPreset()`, replace health clearing with:

```swift
providerStatus.clearDiagnosticsForTargetChange()
```

- [ ] **Step 8: Run Settings compile gate**

Run:

```bash
make build
```

Expected: PASS.

### Task 3: Add Actionable Chat ProviderControlMenu

**Files:**
- Create: `Sources/Yakamoz/Views/ProviderControlMenu.swift`
- Modify: `Sources/Yakamoz/Views/ChatView.swift`

**Interfaces:**
- Consumes: `ProviderStatusViewModel`, `ProviderSettings`, `YakamozRuntime`.
- Produces: `ProviderControlMenu` SwiftUI view and chat toolbar integration.

- [ ] **Step 1: Create ProviderControlMenu**

Create `Sources/Yakamoz/Views/ProviderControlMenu.swift`:

```swift
import SwiftUI
import YakamozCore

struct ProviderControlMenu: View {
    @Bindable var viewModel: ProviderStatusViewModel
    let openSettings: () -> Void

    var body: some View {
        Menu {
            Section("Active Target") {
                LabeledContent("Provider", value: viewModel.providerLabel)
                LabeledContent("Endpoint", value: viewModel.endpointHostLabel)
                LabeledContent("Model", value: viewModel.currentModel.isEmpty ? "Not set" : viewModel.currentModel)
                if let healthStatus = viewModel.healthStatus {
                    Label(healthLabel(healthStatus), systemImage: healthImage(healthStatus))
                } else {
                    Label("Not checked", systemImage: "questionmark.circle")
                }
            }

            if !viewModel.rankedModels.isEmpty {
                Section("Models") {
                    ForEach(viewModel.rankedModels, id: \.self) { modelID in
                        Button {
                            viewModel.selectModel(modelID)
                        } label: {
                            if modelID == viewModel.currentModel {
                                Label(modelID, systemImage: "checkmark")
                            } else {
                                Text(modelID)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingModels)

                Button {
                    viewModel.toggleFavoriteCurrentModel()
                } label: {
                    Label(
                        viewModel.isCurrentModelFavorite ? "Unfavorite Current Model" : "Favorite Current Model",
                        systemImage: viewModel.isCurrentModelFavorite ? "star.slash" : "star"
                    )
                }
                .disabled(viewModel.currentModel.isEmpty)

                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    Label("Test Connection", systemImage: "wave.3.right")
                }
                .disabled(viewModel.isCheckingHealth)

                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
            }

            if let modelLoadError = viewModel.modelLoadError {
                Section {
                    Text(modelLoadError)
                }
            }
        } label: {
            Label(viewModel.toolbarTitle, systemImage: toolbarImage)
                .lineLimit(1)
        }
        .help("Provider: \(viewModel.providerLabel), endpoint: \(viewModel.endpointHostLabel), model: \(viewModel.currentModel)")
        .task {
            if viewModel.rankedModels.isEmpty {
                await viewModel.refreshModels()
            }
        }
    }

    private var toolbarImage: String {
        guard let status = viewModel.healthStatus else { return "network" }
        return healthImage(status)
    }

    private func healthLabel(_ status: AppHealthStatus) -> String {
        switch status {
        case .ok: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        }
    }

    private func healthImage(_ status: AppHealthStatus) -> String {
        switch status {
        case .ok: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        case .down: "xmark.circle"
        }
    }
}
```

- [ ] **Step 2: Wire ChatView environment and state**

In `Sources/Yakamoz/Views/ChatView.swift`, add:

```swift
@Environment(\.providerSettings) private var providerSettings
@State private var providerStatus: ProviderStatusViewModel?
```

- [ ] **Step 3: Add the toolbar item**

In `ChatView.toolbar`, add a toolbar item before the Inspector button:

```swift
ToolbarItem(placement: .automatic) {
    if let providerStatus {
        ProviderControlMenu(viewModel: providerStatus) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
```

- [ ] **Step 4: Build provider status when runtime/settings are available**

Add this task modifier to `ChatView.body`:

```swift
.task(id: providerStatusKey) {
    buildProviderStatusIfNeeded()
}
```

Add:

```swift
private var providerStatusKey: String {
    guard let providerSettings else { return "missing" }
    return "\(ObjectIdentifier(providerSettings).hashValue)"
}

private func buildProviderStatusIfNeeded() {
    guard providerStatus == nil, let runtime, let providerSettings else { return }
    providerStatus = ProviderStatusViewModel(settings: providerSettings, runtime: runtime)
}
```

- [ ] **Step 5: Run build**

Run:

```bash
make build
```

Expected: PASS.

### Task 4: Ticket Docs and Verification

**Files:**
- Modify: `docs/tickets/YAK-22-settings-ux-polish.md`
- Modify: `docs/tickets/README.md`

**Interfaces:**
- Consumes: passing implementation and tests.
- Produces: YAK-22 marked Done, ticket index updated, clean final commit.

- [ ] **Step 1: Run focused tests**

Run:

```bash
make test TEST_FILTER=ProviderStatusViewModelTests
make test TEST_FILTER=ProviderConfigurationTests
make test TEST_FILTER=RuntimeCompositionTests
```

Expected: all PASS with non-zero tests executed.

- [ ] **Step 2: Run full verification**

Run:

```bash
make verify
```

Expected: PASS, and the gate reports non-zero executed tests.

- [ ] **Step 3: Mark YAK-22 done**

Append this resolution note to `docs/tickets/YAK-22-settings-ux-polish.md`:

```markdown
## Resolution

> **Done.** YAK-22 now has a shared provider-status boundary in `YakamozCore`, a reorganized
> Settings surface for active target, credentials, diagnostics, generation, and retry, and an
> actionable chat toolbar provider/model menu for model switching, model refresh, favorite
> toggling, connection checks, and opening Settings. Failure states remain non-blocking and
> manual model entry remains available for custom endpoints and provider-list failures.
```

Change the status line to:

```markdown
- **Status:** Done
```

- [ ] **Step 4: Update the ticket index**

In `docs/tickets/README.md`, change the YAK-22 table row status from `Open` to `Done`.
Remove YAK-22 from the `**Open:**` summary line.

- [ ] **Step 5: Clean up repo state**

Run:

```bash
git status --short
```

Expected: only YAK-22 source, tests, spec, plan, and ticket docs are modified/untracked. If
unrelated files appear, do not stage them; mention them before committing.

- [ ] **Step 6: Commit intended files only**

Run:

```bash
git add Sources/YakamozCore/Configuration/ProviderStatusViewModel.swift \
  Sources/Yakamoz/Views/ProviderControlMenu.swift \
  Sources/Yakamoz/Views/SettingsView.swift \
  Sources/Yakamoz/Views/ChatView.swift \
  Tests/YakamozTests/ProviderStatusViewModelTests.swift \
  docs/superpowers/specs/2026-06-29-yak-22-provider-settings-design.md \
  docs/superpowers/plans/2026-06-29-yak-22-provider-settings.md \
  docs/tickets/YAK-22-settings-ux-polish.md \
  docs/tickets/README.md
git commit -m "feat: polish provider settings and chat control"
```

Expected: one commit containing only YAK-22 work.

