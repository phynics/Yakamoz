import SwiftUI
import YakamozCore

/// Provider settings scene (Command-comma).
///
/// Organized into five groups: Active Target, Credentials, Diagnostics, Generation, Retry.
/// Reads and drives `ProviderStatusViewModel` (shared with `ProviderControlMenu`) so
/// model-list and health state are not duplicated. Non-secret fields write straight through
/// to the injected `ProviderSettings`; the API key is staged in local `@State` and only
/// reaches the secret store when the user taps Apply.
struct SettingsView: View {
    let providerStatus: ProviderStatusViewModel
    @Bindable var settings: ProviderSettings
    let secrets: any SecretStoring

    @State private var apiKeyDraft: String = ""
    @State private var applyError: String?

    var body: some View {
        Form {
            activeTargetSection
            credentialsSection
            diagnosticsSection
            generationSection
            retrySection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 480)
        .task {
            apiKeyDraft = providerStatus.loadAPIKey()
            if providerStatus.availableModels.isEmpty {
                await providerStatus.refreshModels()
            }
        }
    }

    // MARK: - Active Target

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
                ProgressView("Loading models…")
                    .controlSize(.small)
            } else if !providerStatus.rankedModels.isEmpty {
                Picker("Suggested Model", selection: suggestedModelBinding) {
                    ForEach(providerStatus.rankedModels, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
            }

            TextField("Model", text: $settings.model)
                .textFieldStyle(.roundedBorder)
                .onChange(of: settings.model) { _, _ in settings.persist() }

            if let modelLoadError = providerStatus.modelLoadError {
                Text(modelLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Models") {
                    Task { await providerStatus.refreshModels() }
                }
                .disabled(providerStatus.isLoadingModels)

                let currentModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentModel.isEmpty {
                    Button(settings.isFavoriteModel(currentModel) ? "Unfavorite" : "Favorite Model") {
                        providerStatus.toggleFavoriteCurrent()
                    }
                }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section("Credentials") {
            SecureField("API Key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            Text("Stored in UserDefaults (plaintext). See README for security context.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Apply API Key") {
                    applyError = nil
                    do {
                        try providerStatus.applyAPIKey(apiKeyDraft)
                        apiKeyDraft = providerStatus.loadAPIKey()
                    } catch {
                        // Redaction: applyAPIKey's errors (missingAPIKey / invalidBaseURL /
                        // secret-store failures) never embed the key or draft, so logging the
                        // user-friendly message is safe.
                        let message = Log.userFriendlyErrorMessage(for: error)
                        Log.appError("failed to apply API key", metadata: ["error": message])
                        applyError = message
                    }
                }
                .accessibilityLabel("Apply API Key")
            }

            if let applyError {
                Text(applyError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
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
                    if let checkedAt = providerStatus.lastHealthCheckAt {
                        Text(checkedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("Endpoint")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(settings.preset == .custom ? settings.baseURL.absoluteString : presetLabel(settings.preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Model")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(settings.model.isEmpty ? "—" : settings.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        Section("Generation") {
            OptionalDoubleField(label: "Temperature", value: $settings.temperature)
                .onChange(of: settings.temperature) { _, _ in settings.persist() }
            OptionalIntField(label: "Max Output Tokens", value: $settings.maxTokens)
                .onChange(of: settings.maxTokens) { _, _ in settings.persist() }
        }
    }

    // MARK: - Retry

    private var retrySection: some View {
        Section("Retry") {
            Stepper("Max Retries: \(settings.maxRetries)", value: $settings.maxRetries, in: 0 ... 10)
                .onChange(of: settings.maxRetries) { _, _ in settings.persist() }

            HStack {
                Text("Timeout (seconds)")
                Spacer()
                TextField(
                    "Timeout",
                    value: $settings.timeoutInterval,
                    format: .number
                )
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .accessibilityLabel("Timeout in seconds")
                .onChange(of: settings.timeoutInterval) { _, _ in settings.persist() }
            }
        }
    }

    // MARK: - Helpers

    private var suggestedModelBinding: Binding<String> {
        Binding(
            get: { settings.model },
            set: { providerStatus.selectModel($0) }
        )
    }

    private var presetBinding: Binding<ProviderPreset> {
        Binding(
            get: { settings.preset },
            set: { newValue in
                settings.applyPreset(newValue)
                settings.persist()
                providerStatus.clearStaleState()
                apiKeyDraft = providerStatus.loadAPIKey()
                applyError = nil
                Task { await providerStatus.refreshModels() }
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { settings.baseURL.absoluteString },
            set: { newValue in
                if let url = URL(string: newValue) {
                    settings.baseURL = url
                    settings.persist()
                    providerStatus.clearStaleState()
                    Task { await providerStatus.refreshModels() }
                }
            }
        )
    }

    private func presetLabel(_ preset: ProviderPreset) -> String {
        switch preset {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }
}

// MARK: - Subviews

private struct HealthStatusBadge: View {
    let status: AppHealthStatus

    var body: some View {
        Label(label, systemImage: systemImage)
            .foregroundStyle(color)
            .accessibilityLabel("Connection status: \(label)")
    }

    private var label: String {
        switch status {
        case .ok: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        }
    }

    private var systemImage: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .degraded: .orange
        case .down: .red
        }
    }
}

private struct OptionalDoubleField: View {
    let label: String
    @Binding var value: Double?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(
                label,
                text: Binding(
                    get: { value.map { String($0) } ?? "" },
                    set: { newValue in value = Double(newValue) }
                )
            )
            .frame(width: 100)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .accessibilityLabel(label)
        }
    }
}

private struct OptionalIntField: View {
    let label: String
    @Binding var value: Int?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(
                label,
                text: Binding(
                    get: { value.map { String($0) } ?? "" },
                    set: { newValue in value = Int(newValue) }
                )
            )
            .frame(width: 100)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .accessibilityLabel(label)
        }
    }
}
