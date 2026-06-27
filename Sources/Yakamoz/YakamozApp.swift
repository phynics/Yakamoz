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

/// Typed environment key for the secret store (UserDefaults-backed in production — see
/// YAK-14), used by `SettingsView` to persist the API key on explicit Apply only.
private struct SecretStoringKey: EnvironmentKey {
    static let defaultValue: (any SecretStoring)? = nil
}

/// Typed environment key for the terminal command approver (YAK-T5). The same instance is
/// injected into `YakamozRuntime` (so `terminal_run` tools route approvals through it) and
/// exposed here so `ChatView` can render the approval banner from its pending list.
private struct TerminalApproverKey: EnvironmentKey {
    static let defaultValue: MainActorApprover? = nil
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

    var terminalApprover: MainActorApprover? {
        get { self[TerminalApproverKey.self] }
        set { self[TerminalApproverKey.self] = newValue }
    }
}

@main
struct YakamozApp: App {
    private let modelContainer: ModelContainer?
    private let runtime: YakamozRuntime?
    private let settings: ProviderSettings
    private let secrets: any SecretStoring
    private let terminalApprover: MainActorApprover
    private let setupError: String?

    @State private var coordinator = UICoordinator()

    init() {
        let settings = ProviderSettings()
        let secrets = UserDefaultsSecretStore()
        self.settings = settings
        self.secrets = secrets
        // Owned here so the same instance backs both the runtime's terminal tools (approval
        // gate) and ChatView's approval banner (pending list).
        let approver = MainActorApprover()
        terminalApprover = approver

        var resolvedStoreDescription = "(store URL not yet resolved)"
        do {
            let storeURL = try Self.resolveStoreURL()
            resolvedStoreDescription = storeURL.path
            Self.migrateLegacyDefaultStoreIfNeeded(to: storeURL)
            Self.migrateLegacyBundleIdStoreIfNeeded(to: storeURL)
            let schema = Schema(YakamozSchema.models)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            WorkspaceAttachmentSupport.pruneOrphanWorkspaces(modelContext: container.mainContext)
            let builtRuntime = try YakamozRuntime(modelContainer: container, settings: settings, secrets: secrets, terminalApprover: approver)
            modelContainer = container
            runtime = builtRuntime
            setupError = nil
        } catch {
            modelContainer = nil
            runtime = nil
            setupError = "\(error.localizedDescription) (store path: \(resolvedStoreDescription))"
        }
    }

    /// Bundle identifier used as the per-app subdirectory under Application Support, and as
    /// the basis for the secret store's `UserDefaults` suite name (YAK-14). Hard-coded rather
    /// than read from `Bundle.main.bundleIdentifier` so both locations stay stable even if the
    /// bundle id is ever changed in `project.yml` (a change there must be a deliberate,
    /// migration-aware decision — YAK-7, YAK-13).
    private static let storeBundleIdentifier = "me.atkn.Yakamoz"

    /// The previous bundle identifier, before the YAK-13 rename. Used only by
    /// `migrateLegacyBundleIdStoreIfNeeded` to relocate a pre-rename store/suite once.
    private static let legacyBundleIdentifier = "com.atakandulker.Yakamoz"

    /// Resolves the explicit SwiftData store location:
    /// `~/Library/Application Support/me.atkn.Yakamoz/Yakamoz.store`.
    /// Creates the containing directory if it does not yet exist.
    private static func resolveStoreURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeDirectory = appSupport.appendingPathComponent(storeBundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        return storeDirectory.appendingPathComponent("Yakamoz.store", isDirectory: false)
    }

    /// One-time relocation of a store left at SwiftData's *implicit* default location
    /// (`~/Library/Application Support/default.store`, the path used before YAK-7 made
    /// the location explicit) to the new explicit `destination`.
    ///
    /// Only runs when a legacy store exists *and* nothing is present at the new path,
    /// so it never clobbers data and becomes a no-op on every subsequent launch (and
    /// on fresh installs, where there is nothing to move). SwiftData keeps the store as
    /// three files — `default.store` plus `-shm`/`-wal` sidecars — so all three are
    /// moved together. Best-effort: any failure is swallowed and the container simply
    /// opens fresh at `destination`, matching the pre-YAK-7 fresh-start behavior.
    private static func migrateLegacyDefaultStoreIfNeeded(to destination: URL) {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let legacyStore = appSupport.appendingPathComponent("default.store", isDirectory: false)
        // Don't move anything if the legacy store is absent or the new store already exists.
        guard fileManager.fileExists(atPath: legacyStore.path),
              !fileManager.fileExists(atPath: destination.path) else { return }

        for suffix in ["", "-shm", "-wal"] {
            let source = appSupport.appendingPathComponent("default.store\(suffix)", isDirectory: false)
            let target = URL(fileURLWithPath: destination.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: target)
        }
    }

    /// One-time relocation of a store left under the *old* bundle identifier's directory
    /// (`~/Library/Application Support/com.atakandulker.Yakamoz/`, used before the YAK-13
    /// rename to `me.atkn.Yakamoz`) to the new explicit `destination`.
    ///
    /// Same shape as `migrateLegacyDefaultStoreIfNeeded`: only runs when a legacy store exists
    /// *and* nothing is present at the new path, so it never clobbers data and is a no-op on
    /// every subsequent launch and on fresh installs. Moves the `Yakamoz.store` file plus its
    /// `-shm`/`-wal` sidecars. Best-effort: any failure is swallowed and the container simply
    /// opens fresh at `destination`.
    private static func migrateLegacyBundleIdStoreIfNeeded(to destination: URL) {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let legacyDirectory = appSupport.appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
        let legacyStore = legacyDirectory.appendingPathComponent("Yakamoz.store", isDirectory: false)
        // Don't move anything if the legacy store is absent or the new store already exists.
        guard fileManager.fileExists(atPath: legacyStore.path),
              !fileManager.fileExists(atPath: destination.path) else { return }

        for suffix in ["", "-shm", "-wal"] {
            let source = legacyDirectory.appendingPathComponent("Yakamoz.store\(suffix)", isDirectory: false)
            let target = URL(fileURLWithPath: destination.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: target)
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
                    .environment(\.terminalApprover, terminalApprover)
                    .environment(\.uiCoordinator, coordinator)
                    .frame(minWidth: 900, minHeight: 620)
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                        // Best-effort teardown of any live terminal shells on quit (YAK-T5).
                        // The OS also reaps these child processes when the app exits; this is the
                        // clean path. No relaunch survival — sessions are not persisted.
                        Task { await runtime.terminalRegistry.terminateAll() }
                    }
            } else {
                ContentUnavailableView(
                    "Yakamoz Failed to Start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(setupError ?? "An unknown error occurred while initializing the app.")
                )
                .frame(minWidth: 900, minHeight: 620)
            }
        }
        .commands {
            YakamozCommands(coordinator: coordinator)
        }
        .defaultSize(width: 1200, height: 820)

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
