import SwiftUI
import YakamozNetwork

/// Detail surface for a selected Ascendant: who it is, whether it can serve, and its
/// Timelines as the way into a Network chat. Protocol and identity details stay
/// available but collapsed, since they're for diagnosis rather than use.
struct NetworkAscendantDetailView: View {
    let key: NetworkObjectKey
    let session: NetworkClientSession
    let onOpenTimeline: (NetworkObjectKey) -> Void

    private var group: NetworkAscendantGroup? {
        NetworkSidebarPresentation
            .group(catalog: session.catalog, openSessions: session.openSessions)
            .ascendants
            .first { $0.id == key }
    }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                NetworkUnavailableView()
            }
        }
        .navigationTitle(group?.ascendant.name ?? "Ascendant")
        .task(id: key) {
            // Retain the snapshot so a later deadvertisement renders offline, not gone.
            session.openSession(key)
        }
    }

    private func content(_ group: NetworkAscendantGroup) -> some View {
        let ascendant = group.ascendant
        let status = NetworkEntityStatus.of(ascendant, isOffline: group.isOffline)
        return NetworkDetailScaffold(
            title: ascendant.name,
            systemImage: "person.crop.circle",
            kind: "Ascendant",
            status: status
        ) {
            if !ascendant.summary.isEmpty {
                Text(ascendant.summary)
                    .textSelection(.enabled)
            }

            GroupBox("Timelines") {
                if group.timelines.isEmpty {
                    Text("This Ascendant doesn't advertise any timelines.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(group.timelines) { timeline in
                            timelineButton(timeline)
                            if timeline.id != group.timelines.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            if !ascendant.capabilities.isEmpty {
                GroupBox("Capabilities") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ascendant.capabilities, id: \.self) { capability in
                            Text(capability)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DisclosureGroup("Details") {
                NetworkDetailsGrid(rows: [
                    ("Backend", ascendant.backendHealth.displayName),
                    ("Backend kind", [ascendant.backendKind, ascendant.backendVersion].compactMap(\.self).joined(separator: " ").ifEmpty("—")),
                    ("Provider", ascendant.provenance.providerID),
                    ("Node", ascendant.provenance.nodeID?.uuidString ?? "—"),
                    ("Protocol", ascendant.compatibility.protocolMajor.map { "v\($0)" } ?? "—"),
                    ("ID", ascendant.key.objectID.uuidString),
                ])
            }
        }
    }

    private func timelineButton(_ timeline: NetworkTimelineRef) -> some View {
        let status = NetworkEntityStatus.of(timeline, isOffline: !session.isLive(timeline.key))
        return Button {
            onOpenTimeline(timeline.key)
        } label: {
            HStack(spacing: 8) {
                NetworkStatusDot(status: status)
                Text(timeline.title)
                if timeline.isPrivate {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
                if timeline.isArchived {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(timeline.title), \(status.label)")
    }
}

/// Detail surface for a selected Network workspace: trust boundary, usability, the
/// tools it contributes, and which Timelines have it attached. Attaching happens from a
/// Network chat's Workspaces menu, where the Timeline is known.
struct NetworkWorkspaceDetailView: View {
    let key: NetworkObjectKey
    let session: NetworkClientSession
    let onOpenTimeline: (NetworkObjectKey) -> Void

    private var workspace: NetworkWorkspaceRef? {
        guard case let .workspace(value)? = session.object(for: key) else { return nil }
        return value
    }

    var body: some View {
        Group {
            if let workspace {
                content(workspace)
            } else {
                NetworkUnavailableView()
            }
        }
        .navigationTitle(workspace?.displayName ?? "Network Workspace")
        .task(id: key) {
            session.openSession(key)
        }
    }

    private func content(_ workspace: NetworkWorkspaceRef) -> some View {
        let status = NetworkEntityStatus.of(workspace, isOffline: !session.isLive(key))
        let attachedTimelines = session.catalog.timelines(attachedTo: workspace)
        return NetworkDetailScaffold(
            title: workspace.displayName,
            systemImage: "externaldrive.connected.to.line.below",
            kind: "Network Workspace",
            status: status
        ) {
            Text(workspace.uri)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Access").foregroundStyle(.secondary)
                        Text(workspace.trustLevel.displayName)
                    }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(workspace.effectiveStatus.displayName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Tools") {
                if workspace.toolNames.isEmpty {
                    Text("No tools advertised.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(workspace.toolNames, id: \.self) { name in
                            Label(name, systemImage: "wrench.and.screwdriver")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Attached To") {
                if attachedTimelines.isEmpty {
                    Text("Not attached to any timeline. Attach it from a network timeline's Workspaces menu.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachedTimelines) { timeline in
                            Button(timeline.title) { onOpenTimeline(timeline.key) }
                                .buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DisclosureGroup("Details") {
                NetworkDetailsGrid(rows: [
                    ("Provider status", workspace.status.displayName),
                    ("Provider", workspace.provenance.providerID),
                    ("Node", workspace.provenance.nodeID?.uuidString ?? "—"),
                    ("Protocol", workspace.compatibility.protocolMajor.map { "v\($0)" } ?? "—"),
                    ("ID", workspace.key.objectID.uuidString),
                ])
            }
        }
    }
}

/// Shared header + scrolling column for network detail surfaces.
private struct NetworkDetailScaffold<Content: View>: View {
    let title: String
    let systemImage: String
    let kind: String
    let status: NetworkEntityStatus
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(kind)
                                .foregroundStyle(.secondary)
                            NetworkStatusPill(status: status)
                        }
                    }
                }

                if let explanation = status.explanation {
                    NetworkNoticeBanner(text: explanation, systemImage: status.symbolName, tint: status.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                content
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The empty state when a selected network object is neither advertised nor retained.
struct NetworkUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "No Longer on the Network",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text("This item isn't advertised anymore. It reappears in the sidebar when its Node advertises it again.")
        )
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
