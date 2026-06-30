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
    let availableTools: [ConversationToolOption]
    let enabledToolIds: Set<String>
    let onSetToolEnabled: (String, Bool) -> Void
    let onCreateTerminal: () -> Void

    /// Persisted traces win when present; otherwise project the live turn's traces.
    private var traces: [ToolTraceDTO] {
        if !persistedTools.isEmpty { return persistedTools }
        return liveTurn?.toolTraceDTOs ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                availableToolsSection
                traceSection
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Built-in tools (always available, e.g. calculator, current date/time).
    private var builtInTools: [ConversationToolOption] {
        availableTools.filter { !$0.requiresWorkspace }
    }

    /// Workspace tools (filesystem tools confined to the attached folder). Only non-empty
    /// when a workspace is attached — `availableTools` already excludes them otherwise.
    private var workspaceTools: [ConversationToolOption] {
        availableTools.filter(\.requiresWorkspace)
    }

    /// Terminal tools would be available if a terminal workspace were attached.
    private var terminalTools: [ConversationToolOption] {
        availableTools.filter(\.requiresTerminal)
    }

    /// True if no terminal is currently attached but terminal tools would be available with one.
    private var shouldShowTerminalCTA: Bool {
        !availableTools.contains { $0.requiresTerminal } && !ConversationToolSupport.terminalToolOptions.isEmpty
    }

    /// YAK-18: groups the flat tool list into "Built-in" (always available) and
    /// "Workspace" (only present, and confined to, an attached folder) sections, using
    /// `ConversationToolOption.requiresWorkspace` to split. The Workspace group renders
    /// only when non-empty, i.e. only when a workspace is attached.
    ///
    /// YAK-30: Also shows a call-to-action for creating a terminal workspace when no
    /// terminal is attached.
    private var availableToolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolGroup(title: "Built-in", tools: builtInTools)
            if !workspaceTools.isEmpty {
                toolGroup(title: "Workspace", tools: workspaceTools)
            }
            if shouldShowTerminalCTA {
                terminalCTA
            }
        }
    }

    private func toolGroup(title: String, tools: [ConversationToolOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(tools) { tool in
                Toggle(isOn: toolBinding(for: tool.id)) {
                    Label(tool.title, systemImage: tool.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(enabledToolIds.count == 1 && enabledToolIds.contains(tool.id))
                .help(tool.requiresWorkspace ? "Available because this conversation has a workspace attached." : "")
            }
        }
    }

    private var terminalCTA: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Terminal tools let the agent run shell commands and interact with your environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onCreateTerminal()
                } label: {
                    Label("Create Terminal Workspace", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Create terminal workspace")
                .help("Create a terminal workspace to enable terminal tools")
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var traceSection: some View {
        if !traces.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tool Calls This Turn")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(traces) { trace in
                    traceCard(trace)
                }
            }
        } else {
            ContentUnavailableView(
                "No Tool Calls",
                systemImage: "wrench.and.screwdriver",
                description: Text("This turn did not call any tools.")
            )
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

            if let arguments = trace.arguments, !arguments.isEmpty {
                labeledBlock("Parameters", text: arguments)
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

    private func toolBinding(for toolID: String) -> Binding<Bool> {
        Binding(
            get: { enabledToolIds.contains(toolID) },
            set: { onSetToolEnabled(toolID, $0) }
        )
    }
}
