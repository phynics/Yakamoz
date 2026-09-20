import SwiftUI
import YakamozNetwork

/// The sidebar's dedicated **Network** group (issue #9).
///
/// Renders discovered Ascendants (expandable to their advertised Timelines),
/// network Workspaces, and any open-but-deadvertised entries as
/// offline/reconnectable. Kept separate from local operator groups; network
/// entities never create an `AgentModel`/`ConversationModel` row.
struct NetworkSidebarSection: View {
    let session: NetworkClientSession

    @State private var expandedAscendants: Set<NetworkObjectKey> = []

    private var group: NetworkSidebarGroup {
        NetworkSidebarPresentation.group(catalog: session.catalog, openSessions: session.openSessions)
    }

    var body: some View {
        Section("Network") {
            switch session.state {
            case .disabled:
                statusRow("Network access is off.", systemImage: "circle.slash")
            case let .failed(reason):
                statusRow(reason, systemImage: "exclamationmark.triangle")
            case .connecting, .retrying:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(session.state.label)
                        .foregroundStyle(.secondary)
                }
            case .online:
                if group.isEmpty {
                    statusRow("No Gnostic objects discovered.", systemImage: "network.slash")
                } else {
                    discoveredContent
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredContent: some View {
        ForEach(group.ascendants) { ascendant in
            DisclosureGroup(isExpanded: expansionBinding(for: ascendant.id)) {
                if ascendant.timelines.isEmpty {
                    Text("No advertised Timelines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(ascendant.timelines) { timeline in
                    NetworkEntityRow(
                        title: timeline.title,
                        subtitle: providerLabel(timeline.provenance),
                        systemImage: "bubble.left",
                        isOffline: group.isOffline(timeline.key),
                        isCompatible: timeline.compatibility.isCompatible
                    )
                    .tag(SidebarSelection.network(.timeline(timeline.key)))
                }
            } label: {
                NetworkEntityRow(
                    title: ascendant.ascendant.name,
                    subtitle: providerLabel(ascendant.ascendant.provenance),
                    systemImage: "person.crop.circle.badge.checkmark",
                    isOffline: ascendant.isOffline,
                    isCompatible: ascendant.ascendant.compatibility.isCompatible
                )
                .tag(SidebarSelection.network(.ascendant(ascendant.id)))
            }
        }

        ForEach(group.workspaces) { workspace in
            NetworkEntityRow(
                title: workspace.uri,
                subtitle: providerLabel(workspace.provenance),
                systemImage: "folder.badge.gearshape",
                isOffline: group.isOffline(workspace.key),
                isCompatible: workspace.compatibility.isCompatible
            )
            .tag(SidebarSelection.network(.workspace(workspace.key)))
        }

        ForEach(group.looseTimelines) { timeline in
            NetworkEntityRow(
                title: timeline.title,
                subtitle: providerLabel(timeline.provenance),
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                isOffline: true,
                isCompatible: timeline.compatibility.isCompatible
            )
            .tag(SidebarSelection.network(.timeline(timeline.key)))
        }
    }

    private func statusRow(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func providerLabel(_ provenance: NetworkProvenance) -> String {
        if let nodeID = provenance.nodeID {
            return "\(provenance.providerID) · node \(nodeID.uuidString.prefix(8))"
        }
        return provenance.providerID
    }

    private func expansionBinding(for key: NetworkObjectKey) -> Binding<Bool> {
        Binding(
            get: { expandedAscendants.contains(key) },
            set: { isExpanded in
                if isExpanded { expandedAscendants.insert(key) } else { expandedAscendants.remove(key) }
            }
        )
    }
}

/// One discovered-object row with provenance, offline, and compatibility badges.
struct NetworkEntityRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isOffline: Bool
    let isCompatible: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isOffline {
                        badge("Offline", color: .orange)
                    }
                    if !isCompatible {
                        badge("Incompatible", color: .red)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
