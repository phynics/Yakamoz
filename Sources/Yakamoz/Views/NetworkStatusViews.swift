import SwiftUI
import YakamozNetwork

extension NetworkEntityStatus {
    /// The colour shared by the status dot, pill, and banner.
    var tint: Color {
        switch self {
        case .live: .green
        case .degraded: .yellow
        case .offline: .secondary
        case .incompatible: .red
        }
    }

    var symbolName: String {
        switch self {
        case .live: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .offline: "wifi.slash"
        case .incompatible: "xmark.octagon.fill"
        }
    }
}

extension NetworkConnectionState {
    var tint: Color {
        switch self {
        case .disabled: .secondary
        case .connecting, .retrying: .orange
        case .online: .green
        case .failed: .red
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "circle.slash"
        case .connecting, .retrying: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// The 8pt status dot network rows share with the local `TimelineRow`.
struct NetworkStatusDot: View {
    let status: NetworkEntityStatus

    var body: some View {
        Circle()
            .fill(status == .live ? Color.secondary.opacity(0.45) : status.tint)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// A compact status capsule for detail headers.
struct NetworkStatusPill: View {
    let status: NetworkEntityStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

/// A full-width inline notice explaining a non-live status or a blocked action.
struct NetworkNoticeBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
    }
}

/// A key/value grid for the collapsible technical details of a network object.
struct NetworkDetailsGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    Text(rows[index].0)
                        .foregroundStyle(.secondary)
                    Text(rows[index].1)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .padding(.top, 6)
    }
}
