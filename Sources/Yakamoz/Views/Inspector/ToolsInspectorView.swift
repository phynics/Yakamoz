import SwiftUI
import YakamozCore

/// Tools tab: every tool call made during the selected turn, in first-seen order, with
/// its lifecycle state, output/error, and elapsed time.
///
/// **Source priority (Task 11):** tool traces are now persisted on the turn's
/// `ResponseDTO` (`InspectionPresentation.response?.tools`), so a reloaded conversation
/// shows historical tool calls. This view prefers those persisted traces; for the
/// *in-flight* turn (which has no persisted response yet) it falls back to the live,
/// in-memory `ChatTurnState` the reducer is building (`liveTurn`). The empty state only
/// shows when neither source has any tool calls.
struct ToolsInspectorView: View {
    /// Persisted tool traces for the selected turn, decoded from the inspection projection.
    let persistedTools: [ToolTraceDTO]
    /// The selected turn's live, in-memory state — used only for the turn currently
    /// streaming, before its response (and traces) have been persisted.
    let liveTurn: ChatTurnState?

    /// Persisted traces win when present; otherwise project the live turn's traces.
    private var traces: [ToolTraceDTO] {
        if !persistedTools.isEmpty { return persistedTools }
        return liveTurn?.toolTraceDTOs ?? []
    }

    var body: some View {
        if !traces.isEmpty {
            content
        } else {
            ContentUnavailableView(
                "No Tool Calls",
                systemImage: "wrench.and.screwdriver",
                description: Text("This turn did not call any tools.")
            )
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(traces) { trace in
                    traceCard(trace)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func traceCard(_ trace: ToolTraceDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trace.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                stateBadge(trace.status)
                if let elapsed = trace.elapsedMillis {
                    Text(String(format: "%.0f ms", elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("Elapsed: \(Int(elapsed)) milliseconds")
                }
            }

            if let output = trace.output, !output.isEmpty {
                labeledBlock("Output", text: output)
            }
            if let error = trace.error, !error.isEmpty {
                labeledBlock("Error", text: error, isError: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private func stateBadge(_ status: ToolTraceStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .attempting: ("Attempting", .orange)
        case .success: ("Succeeded", .green)
        case .failure: ("Failed", .red)
        }
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Status: \(label)")
    }

    private func labeledBlock(_ title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(title): \(text)")
        }
    }
}
