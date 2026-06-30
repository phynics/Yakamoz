import SwiftUI
import YakamozCore

/// Compact chat-toolbar control showing the active provider/model and connection state.
///
/// Exposes quick-action menu items (model switch, refresh, favorite toggle, connection test,
/// open Settings) without requiring the user to leave chat. Shares `ProviderStatusViewModel`
/// with `SettingsView` so model-list and health state are not duplicated.
struct ProviderControlMenu: View {
    let status: ProviderStatusViewModel
    @Bindable var settings: ProviderSettings

    var body: some View {
        Menu {
            // Header info rows (disabled items used as labels)
            Section {
                Text(presetLabel)
                    .foregroundStyle(.secondary)
                if let host = settings.baseURL.host {
                    Text(host)
                        .foregroundStyle(.secondary)
                }
                Text(settings.model.isEmpty ? "No model selected" : settings.model)
                    .foregroundStyle(.secondary)
                if let health = status.healthStatus {
                    healthLabel(health)
                }
            }

            Divider()

            // Ranked model selection
            if !status.rankedModels.isEmpty {
                Section("Switch Model") {
                    ForEach(status.rankedModels.prefix(8), id: \.self) { modelID in
                        Button {
                            status.selectModel(modelID)
                        } label: {
                            HStack {
                                Text(modelID)
                                if modelID == settings.model {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
            }

            // Actions
            Button {
                Task { await status.refreshModels() }
            } label: {
                Label(
                    status.isLoadingModels ? "Refreshing…" : "Refresh Models",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(status.isLoadingModels)

            let currentModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentModel.isEmpty {
                Button {
                    status.toggleFavoriteCurrent()
                } label: {
                    let isFav = settings.isFavoriteModel(currentModel)
                    Label(
                        isFav ? "Unfavorite Current Model" : "Favorite Current Model",
                        systemImage: isFav ? "star.slash" : "star"
                    )
                }
            }

            Button {
                Task { await status.testConnection() }
            } label: {
                Label(
                    status.isCheckingHealth ? "Testing…" : "Test Connection",
                    systemImage: "network"
                )
            }
            .disabled(status.isCheckingHealth)

            Divider()

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
        } label: {
            menuLabel
        }
        .help(menuHelp)
    }

    // MARK: - Label

    private var menuLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(truncatedModel)
                .lineLimit(1)
        }
        .accessibilityLabel(menuHelp)
    }

    private var truncatedModel: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return presetLabel }
        let maxLen = 24
        return model.count > maxLen ? String(model.prefix(maxLen)) + "…" : model
    }

    private var presetLabel: String {
        switch settings.preset {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }

    private var statusSymbol: String {
        if status.isCheckingHealth || status.isLoadingModels { return "network" }
        switch status.healthStatus {
        case .ok: return "checkmark.circle"
        case .degraded: return "exclamationmark.triangle"
        case .down: return "xmark.circle"
        case nil: return "network"
        }
    }

    private var statusColor: Color {
        switch status.healthStatus {
        case .ok: .green
        case .degraded: .orange
        case .down: .red
        case nil: .secondary
        }
    }

    private var menuHelp: String {
        let base = "\(presetLabel) / \(settings.baseURL.host ?? settings.baseURL.absoluteString)"
        guard let health = status.healthStatus else { return base }
        let healthLabel = switch health {
        case .ok: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        }
        return "\(base) — \(healthLabel)"
    }

    // MARK: - Helpers

    @ViewBuilder
    private func healthLabel(_ health: AppHealthStatus) -> some View {
        let (label, symbol, color): (String, String, Color) = switch health {
        case .ok: ("Healthy", "checkmark.circle.fill", .green)
        case .degraded: ("Degraded", "exclamationmark.triangle.fill", .orange)
        case .down: ("Down", "xmark.circle.fill", .red)
        }
        Label(label, systemImage: symbol)
            .foregroundStyle(color)
    }
}
