import SwiftUI
import YakamozCore

/// Monad server profile settings scene (YAK-MON-9), shown as a second tab alongside
/// `SettingsView`'s local-provider settings.
///
/// Deliberately separate state from `SettingsView`/`ProviderStatusViewModel`: this view edits
/// the active *Monad server connection* (a `MonadProfile` — display name, server URL, API
/// key), not Yakamoz's local LLM provider settings. It only ever *observes* the server's own
/// readiness (`MonadConnectionStatus`) — it never writes the server's provider configuration.
struct MonadServerSettingsView: View {
    let status: MonadProfileStatusViewModel

    @State private var displayNameDraft: String = ""
    @State private var serverURLDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var saveError: String?
    @State private var applyKeyError: String?

    var body: some View {
        Form {
            profileSection
            credentialsSection
            statusSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 420)
        .task {
            loadDraftsFromActiveProfile()
            await status.checkStatus()
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("Monad Server Profile") {
            TextField("Display Name", text: $displayNameDraft)
                .textFieldStyle(.roundedBorder)

            TextField("Server URL", text: $serverURLDraft, prompt: Text("http://127.0.0.1:8080"))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            HStack {
                Button("Save Profile") {
                    saveError = nil
                    do {
                        try status.saveProfile(displayName: displayNameDraft, serverURLString: serverURLDraft)
                        loadDraftsFromActiveProfile()
                        Task { await status.checkStatus() }
                    } catch {
                        saveError = Log.userFriendlyErrorMessage(for: error)
                    }
                }
                .accessibilityLabel("Save Profile")

                Button("Check Connection") {
                    Task { await status.checkStatus() }
                }
                .disabled(status.isChecking)
                .accessibilityLabel("Check Connection")
            }

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section("Credentials") {
            SecureField("API Key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            Text("Stored in UserDefaults (plaintext). Optional — only needed if the server requires one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Apply API Key") {
                applyKeyError = nil
                do {
                    try status.applyAPIKey(apiKeyDraft)
                    apiKeyDraft = status.loadAPIKey()
                    Task { await status.checkStatus() }
                } catch {
                    applyKeyError = Log.userFriendlyErrorMessage(for: error)
                }
            }
            .accessibilityLabel("Apply API Key")

            if let applyKeyError {
                Text(applyKeyError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Status (read-only)

    private var statusSection: some View {
        Section("Server Status") {
            HStack {
                MonadConnectionStatusBadge(status: status.status)
                if status.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if let checkedAt = status.lastCheckedAt {
                    Text(checkedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(statusDetailMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusDetailMessage: String {
        switch status.status {
        case .profileMissing:
            "Save a server profile above, then check the connection."
        case let .unreachable(message):
            "The server could not be reached: \(message)"
        case .authenticationFailed:
            "The server rejected the configured API key."
        case .providerNotConfigured:
            "The server is reachable, but it has no LLM provider configured. This is server-side configuration Yakamoz does not write."
        case .healthy:
            "The server is reachable and ready."
        case let .unexpectedResponse(message):
            "The server returned an unexpected response: \(message)"
        }
    }

    private func loadDraftsFromActiveProfile() {
        if let profile = status.activeProfile {
            displayNameDraft = profile.displayName
            serverURLDraft = profile.serverURL.absoluteString
        }
        apiKeyDraft = status.loadAPIKey()
    }
}

// MARK: - Subviews

private struct MonadConnectionStatusBadge: View {
    let status: MonadConnectionStatus

    var body: some View {
        Label(label, systemImage: systemImage)
            .foregroundStyle(color)
            .accessibilityLabel("Monad server status: \(label)")
    }

    private var label: String {
        switch status {
        case .profileMissing: "No Profile"
        case .unreachable: "Unreachable"
        case .authenticationFailed: "Auth Failed"
        case .providerNotConfigured: "Provider Not Configured"
        case .healthy: "Healthy"
        case .unexpectedResponse: "Unexpected Response"
        }
    }

    private var systemImage: String {
        switch status {
        case .profileMissing: "questionmark.circle"
        case .unreachable: "xmark.circle.fill"
        case .authenticationFailed: "lock.trianglebadge.exclamationmark.fill"
        case .providerNotConfigured: "exclamationmark.triangle.fill"
        case .healthy: "checkmark.circle.fill"
        case .unexpectedResponse: "questionmark.diamond.fill"
        }
    }

    private var color: Color {
        switch status {
        case .profileMissing: .secondary
        case .unreachable, .authenticationFailed: .red
        case .providerNotConfigured, .unexpectedResponse: .orange
        case .healthy: .green
        }
    }
}
