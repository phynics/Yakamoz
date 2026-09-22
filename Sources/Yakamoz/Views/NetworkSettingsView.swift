import SwiftUI
import YakamozCore
import YakamozNetwork

/// The Network settings pane (issue #7).
///
/// Mirrors the Provider pane's UX: non-secret fields write straight through to
/// the injected ``NetworkSettings``, while the broker password is staged in local
/// `@State` and only reaches the secret store on explicit Apply. Every change is
/// persisted and pushed to the session; an enable/disable edge reconnects or
/// disconnects the client. Field edits made while connected are held by the session
/// (never reconnecting per keystroke) and applied by the status section's Reconnect.
struct NetworkSettingsView: View {
    @Bindable var settings: NetworkSettings
    let session: NetworkClientSession?
    let secrets: any SecretStoring

    @State private var passwordDraft = ""
    @State private var applyError: String?

    var body: some View {
        Form {
            statusSection
            connectionSection
            credentialsSection
        }
        .formStyle(.grouped)
        .task {
            passwordDraft = (try? settings.storedPassword(secrets: secrets)) ?? ""
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Broker") {
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
        .disabled(!settings.isEnabled)
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
        .disabled(!settings.isEnabled)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            Toggle("Connect to a Gnostic network", isOn: $settings.isEnabled)
                .onChange(of: settings.isEnabled) { _, _ in persistAndApply() }

            if let session, settings.isEnabled {
                HStack {
                    Label(session.state.shortLabel, systemImage: session.state.symbolName)
                        .foregroundStyle(session.state.tint)
                    Spacer()
                    if session.state.isOnline {
                        Button("Refresh Discovery") {
                            Task { await session.forceRefresh() }
                        }
                    }
                    if session.state.failureMessage != nil || session.needsReconnect {
                        Button("Reconnect") {
                            Task { await session.reconnect() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let failure = session.state.failureMessage {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if session.needsReconnect {
                    Text("Broker settings changed. Reconnect to apply them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if session == nil {
                Text("Network client unavailable.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Yakamoz joins as a client: it discovers Ascendants, timelines, and workspaces on the broker and hosts nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
}
