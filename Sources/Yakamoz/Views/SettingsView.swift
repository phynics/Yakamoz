import SwiftUI
import YakamozCore

/// Provider settings scene (Command-comma). Non-secret fields write straight through
/// to the injected `ProviderSettings` (and are persisted via `persist()` on change);
/// the API key is staged in local `@State` and only reaches the Keychain when the user
/// taps Apply.
struct SettingsView: View {
    let runtime: YakamozRuntime
    @Bindable var settings: ProviderSettings
    let secrets: any SecretStoring

    @State private var apiKeyDraft: String = ""
    @State private var applyError: String?
    @State private var healthStatus: AppHealthStatus?
    @State private var isCheckingHealth = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: presetBinding) {
                    ForEach(ProviderPreset.allCases, id: \.self) { preset in
                        Text(presetLabel(preset)).tag(preset)
                    }
                }

                TextField("Base URL", text: baseURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                SecureField("API Key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.model) { _, _ in settings.persist() }
            }

            Section("Generation") {
                OptionalDoubleField(label: "Temperature", value: $settings.temperature)
                    .onChange(of: settings.temperature) { _, _ in settings.persist() }
                OptionalIntField(label: "Max Output Tokens", value: $settings.maxTokens)
                    .onChange(of: settings.maxTokens) { _, _ in settings.persist() }
            }

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

            Section {
                HStack {
                    Button("Apply API Key") {
                        applyAPIKey()
                    }
                    .accessibilityLabel("Apply API Key")

                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isCheckingHealth)
                    .accessibilityLabel("Test Connection")

                    if isCheckingHealth {
                        ProgressView()
                            .controlSize(.small)
                    } else if let healthStatus {
                        HealthStatusBadge(status: healthStatus)
                    }
                }

                if let applyError {
                    Text(applyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 420)
        .task {
            loadAPIKeyForSelectedPreset()
        }
    }

    private var presetBinding: Binding<ProviderPreset> {
        Binding(
            get: { settings.preset },
            set: { newValue in
                settings.applyPreset(newValue)
                settings.persist()
                loadAPIKeyForSelectedPreset()
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

    private func applyAPIKey() {
        applyError = nil
        let normalizedKey = ProviderSettings.normalizeAPIKey(apiKeyDraft)
        do {
            try settings.validateBaseURL()
            try settings.validateAPIKey(normalizedKey)
            let account = ProviderSettings.apiKeyAccount(for: settings.preset)
            if normalizedKey.isEmpty {
                try secrets.delete(account: account)
            } else {
                try secrets.write(normalizedKey, account: account)
            }
            apiKeyDraft = normalizedKey
        } catch {
            applyError = error.localizedDescription
        }
    }

    private func loadAPIKeyForSelectedPreset() {
        apiKeyDraft = (try? ProviderSettings.storedAPIKey(for: settings.preset, secrets: secrets)) ?? ""
        applyError = nil
        healthStatus = nil
    }

    private func testConnection() async {
        isCheckingHealth = true
        healthStatus = await runtime.appHealthCheck()
        isCheckingHealth = false
    }
}

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
