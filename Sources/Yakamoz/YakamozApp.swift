import SwiftData
import SwiftUI
import YakamozCore

/// Typed environment key for the composed `YakamozRuntime` (PositronicKit facade,
/// SwiftData-backed stores, turn inspector). `nil` when construction failed; views
/// that require it should fall back to an error/unavailable state rather than force-unwrap.
private struct YakamozRuntimeKey: EnvironmentKey {
    static let defaultValue: YakamozRuntime? = nil
}

/// Typed environment key for the observable provider settings (Task 5), shared by the
/// settings scene and any view that needs to read provider configuration.
private struct ProviderSettingsKey: EnvironmentKey {
    static let defaultValue: ProviderSettings? = nil
}

/// Typed environment key for the secret store (Keychain in production), used by
/// `SettingsView` to persist the API key on explicit Apply only.
private struct SecretStoringKey: EnvironmentKey {
    static let defaultValue: (any SecretStoring)? = nil
}

extension EnvironmentValues {
    var yakamozRuntime: YakamozRuntime? {
        get { self[YakamozRuntimeKey.self] }
        set { self[YakamozRuntimeKey.self] = newValue }
    }

    var providerSettings: ProviderSettings? {
        get { self[ProviderSettingsKey.self] }
        set { self[ProviderSettingsKey.self] = newValue }
    }

    var secretStore: (any SecretStoring)? {
        get { self[SecretStoringKey.self] }
        set { self[SecretStoringKey.self] = newValue }
    }
}

@main
struct YakamozApp: App {
    private let modelContainer: ModelContainer?
    private let runtime: YakamozRuntime?
    private let settings: ProviderSettings
    private let secrets: any SecretStoring
    private let setupError: String?

    init() {
        let settings = ProviderSettings()
        let secrets = KeychainStore()
        self.settings = settings
        self.secrets = secrets

        do {
            let schema = Schema(YakamozSchema.models)
            let configuration = ModelConfiguration(schema: schema)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let builtRuntime = try YakamozRuntime(modelContainer: container, settings: settings, secrets: secrets)
            modelContainer = container
            runtime = builtRuntime
            setupError = nil
        } catch {
            modelContainer = nil
            runtime = nil
            setupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer, let runtime {
                ContentView()
                    .modelContainer(modelContainer)
                    .environment(\.yakamozRuntime, runtime)
                    .environment(\.providerSettings, settings)
                    .environment(\.secretStore, secrets)
            } else {
                ContentUnavailableView(
                    "Yakamoz Failed to Start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(setupError ?? "An unknown error occurred while initializing the app.")
                )
            }
        }

        Settings {
            if let runtime {
                SettingsView(runtime: runtime, settings: settings, secrets: secrets)
            } else {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(setupError ?? "The app runtime failed to initialize.")
                )
            }
        }
    }
}
