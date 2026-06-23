import SwiftUI
import YakamozCore

/// Tools tab: every tool call made during the selected turn, in first-seen order, with
/// its lifecycle state, output/error, and elapsed time.
///
/// **Known v1 limitation (Gap 1):** tool traces live only in the in-memory
/// `ChatTurnState` the reducer builds while a turn streams (`ChatViewModel.selectedTurnState`)
/// — they are NOT persisted anywhere. `SwiftDataTurnInspector`/`InspectionPresentation`
/// (the source for the other three inspector tabs) carry prompt/sent/journal/response
/// data that survives a relaunch, but no tool-trace projection. That means: after the app
/// restarts and a conversation is reloaded from disk, this tab renders the "no tool calls"
/// empty state for every historical turn, even if that turn actually called tools when it
/// ran live. Tool traces are only visible for turns observed during the current session.
/// Persisting them would mean adding a `ToolTraceDTO`-shaped column to
/// `SwiftDataTurnInspector`'s response projection (`InspectionDTOs.swift`) and populating
/// it from `ChatEventReducer`'s `ToolTrace` list in `ChatEngine+ContextBuilding`/
/// `ChatEngine+ToolExecution`-equivalent persistence hooks — left for a follow-up task.
struct ToolsInspectorView: View {
    let turn: ChatTurnState?

    var body: some View {
        if let turn, !turn.toolOrder.isEmpty {
            content(turn)
        } else {
            ContentUnavailableView(
                "No Tool Calls",
                systemImage: "wrench.and.screwdriver",
                description: Text(emptyDescription)
            )
        }
    }

    private var emptyDescription: String {
        "Tool traces are only available for turns observed in this session; they are not persisted across relaunches."
    }

    private func content(_ turn: ChatTurnState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(turn.toolOrder, id: \.self) { callId in
                    if let trace = turn.tools[callId] {
                        traceCard(trace)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func traceCard(_ trace: ToolTrace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trace.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                stateBadge(trace.state)
                if let elapsed = trace.elapsed {
                    Text(formatted(elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
    }

    private func stateBadge(_ state: ToolTraceState) -> some View {
        let (label, color): (String, Color) = switch state {
        case .attempting: ("Attempting", .orange)
        case .succeeded: ("Succeeded", .green)
        case .failed: ("Failed", .red)
        }
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("State: \(label)")
    }

    private func labeledBlock(_ title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatted(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let millis = Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
        return String(format: "%.0f ms", millis)
    }
}
