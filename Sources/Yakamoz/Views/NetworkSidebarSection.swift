import SwiftUI
import YakamozNetwork

/// The sidebar's **Network** sections (issue #9).
///
/// Mirrors the local agent tree: Ascendants expand to their advertised Timelines (rows
/// styled like the local `TimelineRow`), loose Timelines follow, and discovered Network
/// workspaces get their own section. Connection status lives in the section header, and a
/// failed or empty network offers a way forward instead of a dead end. Network entities
/// never create an `AgentModel`/`ConversationModel` row.
struct NetworkSidebarSection: View {
    let session: NetworkClientSession
    let selection: SidebarSelection?

    @State private var expandedAscendants: Set<NetworkObjectKey> = []

    private var group: NetworkSidebarGroup {
        NetworkSidebarPresentation.group(catalog: session.catalog, openSessions: session.openSessions)
    }

    var body: some View {
        Section {
            switch session.state {
            case .disabled:
                statusRow("Network access is off.", systemImage: "circle.slash")
                SettingsLink { Text("Open Network Settings…") }
                    .buttonStyle(.link)
            case let .failed(reason):
                statusRow(reason, systemImage: "exclamationmark.triangle")
                HStack {
                    Button("Retry") { Task { await session.reconnect() } }
                    SettingsLink { Text("Settings…") }
                }
                .buttonStyle(.link)
            case .connecting, .retrying:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(session.state.label)
                        .foregroundStyle(.secondary)
                }
            case .online:
                if group.ascendants.isEmpty, group.looseTimelines.isEmpty {
                    statusRow("No Ascendants advertised yet.", systemImage: "antenna.radiowaves.left.and.right.slash")
                } else {
                    timelineContent
                }
            }
        } header: {
            header
        }
        .onChange(of: selection, initial: true) { _, newValue in
            revealSelectedTimeline(newValue)
        }

        if session.state.isOnline, !group.workspaces.isEmpty {
            Section("Network Workspaces") {
                ForEach(group.workspaces) { workspace in
                    NetworkWorkspaceRow(
                        workspace: workspace,
                        status: .of(workspace, isOffline: group.isOffline(workspace.key))
                    )
                    .tag(SidebarSelection.network(.workspace(workspace.key)))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Network")
            Spacer()
            Image(systemName: session.state.symbolName)
                .foregroundStyle(session.state.tint)
                .help(session.state.label)
                .accessibilityLabel("Network \(session.state.shortLabel)")
            if session.state.isOnline {
                Button {
                    Task { await session.forceRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh discovery")
                .accessibilityLabel("Refresh Network")
            }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        ForEach(group.ascendants) { ascendantGroup in
            let status = NetworkEntityStatus.of(ascendantGroup.ascendant, isOffline: ascendantGroup.isOffline)
            DisclosureGroup(isExpanded: expansionBinding(for: ascendantGroup.id)) {
                if ascendantGroup.timelines.isEmpty {
                    Text("No advertised timelines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(ascendantGroup.timelines) { timeline in
                    timelineRow(timeline)
                }
            } label: {
                HStack(spacing: 6) {
                    Label(ascendantGroup.ascendant.name, systemImage: "person.crop.circle")
                    Spacer(minLength: 0)
                    if status != .live {
                        NetworkStatusDot(status: status)
                    }
                }
                .help(tooltip(ascendantGroup.ascendant.provenance, status: status))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(ascendantGroup.ascendant.name), \(status.label)")
                .tag(SidebarSelection.network(.ascendant(ascendantGroup.id)))
            }
        }

        ForEach(group.looseTimelines) { timeline in
            timelineRow(timeline)
        }
    }

    private func timelineRow(_ timeline: NetworkTimelineRef) -> some View {
        NetworkTimelineRow(
            timeline: timeline,
            status: .of(timeline, isOffline: group.isOffline(timeline.key))
        )
        .tag(SidebarSelection.network(.timeline(timeline.key)))
    }

    private func statusRow(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func tooltip(_ provenance: NetworkProvenance, status: NetworkEntityStatus) -> String {
        [provenance.displayName, status.explanation].compactMap(\.self).joined(separator: "\n")
    }

    /// Expands the Ascendant that owns a newly selected Timeline, so selecting one from a
    /// detail view never leaves the selection hidden inside a collapsed group.
    private func revealSelectedTimeline(_ selection: SidebarSelection?) {
        guard case let .network(.timeline(key))? = selection,
              let owner = group.ascendants.first(where: { $0.timelines.contains { $0.key == key } })
        else { return }
        expandedAscendants.insert(owner.id)
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

/// A Gnostic Timeline row, laid out like the local `TimelineRow`.
private struct NetworkTimelineRow: View {
    let timeline: NetworkTimelineRef
    let status: NetworkEntityStatus

    var body: some View {
        HStack(spacing: 8) {
            NetworkStatusDot(status: status)
            Text(timeline.title)
                .foregroundStyle(status == .offline ? .secondary : .primary)
            Spacer(minLength: 0)
            if timeline.isPrivate {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Private")
            }
            if timeline.isArchived {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Archived")
            }
            if !timeline.attachedWorkspaceIDs.isEmpty {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(timeline.attachedWorkspaceIDs.count == 1
                        ? "Has Network Workspace"
                        : "Has \(timeline.attachedWorkspaceIDs.count) Network Workspaces")
            }
        }
        .padding(.vertical, 2)
        .help([timeline.provenance.displayName, status.explanation].compactMap(\.self).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeline.title), \(status.label)")
    }
}

/// A Network workspace row: short name, trust level, and a status dot.
private struct NetworkWorkspaceRow: View {
    let workspace: NetworkWorkspaceRef
    let status: NetworkEntityStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                Text(workspace.trustLevel.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status != .live {
                NetworkStatusDot(status: status)
            }
        }
        .padding(.vertical, 2)
        .help([workspace.uri, status.explanation].compactMap(\.self).joined(separator: "\n"))
        .contextMenu {
            Button("Copy URI") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.uri, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.displayName), \(workspace.trustLevel.displayName), \(status.label)")
    }
}
