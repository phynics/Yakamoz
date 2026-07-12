import SwiftUI
import YakamozCore

struct MonadInspectorView: View {
    let turnState: ChatTurnState?
    @Binding var selectedTab: MonadInspectorTab
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Inspector Tab", selection: $selectedTab) {
                ForEach(MonadInspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
            .accessibilityLabel("Close inspector")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var paneContent: some View {
        if !selectedTab.availableInMonad {
            unavailableTab(selectedTab)
        } else if let turnState {
            availableTab(selectedTab, turnState: turnState)
        } else {
            ContentUnavailableView(
                "No Turn Selected",
                systemImage: "cursorarrow.rays",
                description: Text("Select an assistant turn to inspect its details.")
            )
        }
    }

    @ViewBuilder
    private func unavailableTab(_ tab: MonadInspectorTab) -> some View {
        ContentUnavailableView(
            "\(tab.title) Not Available",
            systemImage: tab.systemImage,
            description: Text("The \(tab.title.lowercased()) inspector is not available for Monad-backed turns yet.")
        )
    }

    @ViewBuilder
    private func availableTab(_ tab: MonadInspectorTab, turnState: ChatTurnState) -> some View {
        switch tab {
        case .response:
            MonadResponseInspectorView(turnState: turnState)
        case .tools:
            ToolsInspectorView(
                persistedTools: [],
                liveTurn: turnState
            )
        case .prompt, .sent, .journal:
            EmptyView()
        }
    }
}

struct MonadResponseInspectorView: View {
    let turnState: ChatTurnState

    private var response: ChatTurnState.Response {
        turnState.response
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                metadata

                if !response.thinking.isEmpty {
                    labeledBlock("Thinking", text: response.thinking, secondary: true)
                }

                labeledBlock(
                    "Generation",
                    text: response.reconstructedText.isEmpty ? "(empty)" : response.reconstructedText
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let model = response.model {
                row("Model", model)
            }
            if let finish = response.finishReason {
                row("Finish reason", finish)
            }
            if let input = response.inputTokens {
                row("Input tokens", "\(input)")
            }
            if let output = response.outputTokens {
                row("Output tokens", "\(output)")
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func labeledBlock(_ title: String, text: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
