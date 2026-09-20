import SwiftUI
import YakamozNetwork

/// Minimal detail surface for a selected network entry (issue #9).
///
/// Shows identity, provenance, and compatibility so the selection "routes to the
/// network chat surface" honestly, without pulling #10's turn execution forward.
/// Network turns, attach, and the inspector tab arrive in follow-up issues.
struct NetworkPlaceholderDetailView: View {
    let selection: NetworkSidebarSelection
    let session: NetworkClientSession

    var body: some View {
        Group {
            switch selection {
            case let .ascendant(key):
                ascendantDetail(key)
            case let .timeline(key):
                timelineDetail(key)
            case let .workspace(key):
                workspaceDetail(key)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ascendant

    @ViewBuilder
    private func ascendantDetail(_ key: NetworkObjectKey) -> some View {
        if case let .ascendant(ascendant)? = object(for: key) {
            detailLayout(
                title: ascendant.name,
                systemImage: "person.crop.circle.badge.checkmark",
                compatibility: ascendant.compatibility,
                rows: [
                    ("Kind", "Ascendant"),
                    ("Provider", ascendant.provenance.providerID),
                    ("Node", ascendant.provenance.nodeID?.uuidString ?? "—"),
                    ("Backend", ascendant.backendHealth.rawValue),
                    ("Capabilities", ascendant.capabilities.isEmpty ? "—" : ascendant.capabilities.joined(separator: ", ")),
                ],
                summary: ascendant.summary
            )
        } else {
            missing
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timelineDetail(_ key: NetworkObjectKey) -> some View {
        if case let .timeline(timeline)? = object(for: key) {
            detailLayout(
                title: timeline.title,
                systemImage: "bubble.left",
                compatibility: timeline.compatibility,
                rows: [
                    ("Kind", "Gnostic Timeline"),
                    ("Provider", timeline.provenance.providerID),
                    ("Node", timeline.provenance.nodeID?.uuidString ?? "—"),
                    ("Archived", timeline.isArchived ? "Yes" : "No"),
                    ("Private", timeline.isPrivate ? "Yes" : "No"),
                    ("Ascendant", timeline.attachedAscendantID?.uuidString ?? "—"),
                ],
                summary: "This timeline is owned by a remote Node; Yakamoz does not persist it as a local conversation."
            )
        } else {
            missing
        }
    }

    // MARK: - Workspace

    @ViewBuilder
    private func workspaceDetail(_ key: NetworkObjectKey) -> some View {
        if case let .workspace(workspace)? = object(for: key) {
            detailLayout(
                title: workspace.uri,
                systemImage: "folder.badge.gearshape",
                compatibility: workspace.compatibility,
                rows: [
                    ("Kind", "Network Workspace"),
                    ("Provider", workspace.provenance.providerID),
                    ("Node", workspace.provenance.nodeID?.uuidString ?? "—"),
                    ("Trust", workspace.trustLevel.rawValue),
                    ("Status", workspace.status.rawValue),
                    ("Effective", workspace.effectiveStatus.rawValue),
                    ("Tools", workspace.toolNames.isEmpty ? "—" : workspace.toolNames.joined(separator: ", ")),
                ],
                summary: "A capability resource a remote Timeline can attach; distinct from a local Yakamoz workspace."
            )
        } else {
            missing
        }
    }

    // MARK: - Shared layout

    private func detailLayout(
        title: String,
        systemImage: String,
        compatibility: NetworkCompatibility,
        rows: [(String, String)],
        summary: String
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: systemImage)
                    .font(.title2.bold())

                if !compatibility.isCompatible {
                    Label(
                        "This object advertises protocol major \(compatibility.protocolMajor.map { String($0) } ?? "unknown"), which this client does not support.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { index in
                        GridRow {
                            Text(rows[index].0)
                                .foregroundStyle(.secondary)
                            Text(rows[index].1)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Label("Network turns arrive in #10.", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            "Network Entry Unavailable",
            systemImage: "network.slash",
            description: Text("The selected object is no longer advertised.")
        )
    }

    private func object(for key: NetworkObjectKey) -> DiscoveredNetworkObject? {
        session.catalog.object(for: key) ?? session.openSessions[key]
    }
}
