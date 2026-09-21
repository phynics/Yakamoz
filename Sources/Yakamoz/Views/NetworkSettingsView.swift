import SwiftUI
import YakamozCore
import YakamozNetwork

/// The Network settings pane (issue #7).
///
/// Mirrors the Provider pane's UX: non-secret fields write straight through to
/// the injected ``NetworkSettings``, while the broker password is staged in local
/// `@State` and only reaches the secret store on explicit Apply. Every change is
/// persisted and pushed to the session; an enable/disable edge reconnects or
/// disconnects the client.
struct NetworkSettingsView: View {
    @Bindable var settings: NetworkSettings
    let session: NetworkClientSession?
    let secrets: any SecretStoring

    @State private var passwordDraft = ""
    @State private var applyError: String?

    var body: some View {
        Form {
            connectionSection
            credentialsSection
            statusSection
        }
        .formStyle(.grouped)
        .task {
            passwordDraft = (try? settings.storedPassword(secrets: secrets)) ?? ""
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            Toggle("Connect to a Gnostic network", isOn: $settings.isEnabled)
                .onChange(of: settings.isEnabled) { _, _ in persistAndApply() }

            TextField("Broker Host", text: $settings.host)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: settings.host) { _, _ in persistAndApply() }

            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $settings.port, format: .number)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                    .accessibilityLabel("Broker Port")
                    .onChange(of: settings.port) { _, _ in persistAndApply() }
            }

            TextField("Namespace", text: $settings.namespace)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: settings.namespace) { _, _ in persistAndApply() }

            TextField("Client Identity", text: $settings.identity)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: settings.identity) { _, _ in persistAndApply() }

            let issues = settings.validate(password: passwordDraft)
            if !issues.isEmpty {
                ForEach(issues, id: \.self) { issue in
                    Text(issue.errorDescription ?? "Invalid network settings.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section("Credentials") {
            TextField("Username", text: $settings.username)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: settings.username) { _, _ in persistAndApply() }

            SecureField("Password", text: $passwordDraft)

            Text("Stored in UserDefaults (plaintext). See README for security context.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Apply Password") {
                applyError = nil
                let draft = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let issue = settings.validate(password: draft.isEmpty ? nil : draft).first {
                    applyError = Log.userFriendlyErrorMessage(for: issue)
                    return
                }
                do {
                    try settings.applyPassword(passwordDraft, secrets: secrets)
                    passwordDraft = (try settings.storedPassword(secrets: secrets)) ?? ""
                    persistAndApply()
                } catch {
                    applyError = Log.userFriendlyErrorMessage(for: error)
                }
            }
            .accessibilityLabel("Apply Password")

            if let applyError {
                Text(applyError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            if let session {
                HStack {
                    Label(session.state.label, systemImage: statusIcon(for: session.state))
                        .foregroundStyle(statusColor(for: session.state))
                    Spacer()
                    if session.state.isOnline {
                        Button("Force Refresh") {
                            Task { await session.forceRefresh() }
                        }
                    }
                }
            } else {
                Text("Network client unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func persistAndApply() {
        settings.persist()
        guard let session else { return }
        let storedPassword = (try? settings.storedPassword(secrets: secrets)) ?? nil
        guard settings.validate(password: storedPassword).isEmpty,
              let configuration = try? settings.brokerConfiguration(secrets: secrets)
        else { return }
        Task { await session.update(configuration: configuration) }
    }

    private func statusIcon(for state: NetworkConnectionState) -> String {
        switch state {
        case .disabled: "circle.slash"
        case .connecting, .retrying: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for state: NetworkConnectionState) -> Color {
        switch state {
        case .disabled: .secondary
        case .connecting, .retrying: .orange
        case .online: .green
        case .failed: .red
        }
    }
}
