import SwiftUI
import YakamozCore

/// One tab of the turn inspector. ⌘1…⌘5 select them in `allCases` order.
enum InspectorTab: String, CaseIterable, Identifiable {
    case prompt
    case sent
    case journal
    case response
    case tools

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .prompt: "Prompt"
        case .sent: "Sent"
        case .journal: "Journal"
        case .response: "Response"
        case .tools: "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .prompt: "text.alignleft"
        case .sent: "paperplane"
        case .journal: "book.closed"
        case .response: "bubble.left.and.bubble.right"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

/// The inspector column: the prompt pipeline "under glass" for one assistant turn.
///
/// Glass only (ADR 0003): it holds no settings and has no modes. It shows the turn the user
/// selected, or follows the latest turn when nothing is selected, so the five tabs always
/// have something to show once the conversation has a reply. Hosted by `ChatView` through the
/// native `.inspector` modifier, which owns presentation and resizing.
///
/// The inspector never owns turn selection: `ChatView` loads `viewModel` for
/// `ChatViewModel.inspectedInspectionTurnIndex`, and the header's **Latest** button clears
/// the selection to resume following.
struct TurnInspector: View {
    let viewModel: InspectionViewModel
    /// The inspected turn's live, in-memory state for the Tools tab (tool traces are not
    /// persisted — see `ToolsInspectorView`).
    let turnState: ChatTurnState?
    let isFollowingLatest: Bool
    let onFollowLatest: () -> Void
    /// The selected tab's raw value, owned by `ChatView` (`@SceneStorage`) so ⌘1…⌘5 can drive it.
    @Binding var selectedTabRaw: String
    /// Journal prev/next navigation, wired to the same selection path as bubble taps.
    let canSelectTurn: (Int) -> Bool
    let onSelectTurn: (Int) -> Void

    private var selectedTab: InspectorTab {
        InspectorTab(rawValue: selectedTabRaw) ?? .prompt
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector Tab", selection: Binding(
                get: { selectedTab },
                set: { selectedTabRaw = $0.rawValue }
            )) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(.iconOnly)
                        .help("\(tab.title) (⌘\((InspectorTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)

            turnHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var turnHeader: some View {
        HStack(spacing: 6) {
            Text(selectedTab.title)
                .font(.headline)
            if let turnState {
                Text("· Turn \(turnState.turnIndex + 1)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isFollowingLatest {
                if turnState != nil {
                    Label("Latest", systemImage: "dot.radiowaves.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Following the latest turn. Click a reply to inspect an older one.")
                }
            } else {
                Button("Latest", systemImage: "arrow.down.to.line", action: onFollowLatest)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Return to the latest turn")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .tools:
            ToolsInspectorView(
                persistedTools: viewModel.inspection?.response?.tools ?? [],
                liveTurn: turnState
            )
        case .prompt, .sent, .journal, .response:
            if let inspection = viewModel.inspection {
                tabView(inspection: inspection)
            } else if let error = viewModel.loadError {
                InspectorEmptyState("Inspection Unavailable", systemImage: "exclamationmark.triangle", detail: error)
            } else {
                InspectorEmptyState(
                    "Nothing to Inspect Yet",
                    systemImage: "cursorarrow.rays",
                    detail: "Once the operator replies, its prompt, request, and response appear here."
                )
            }
        }
    }

    @ViewBuilder
    private func tabView(inspection: InspectionPresentation) -> some View {
        switch selectedTab {
        case .prompt:
            PromptInspectorView(inspection: inspection)
        case .sent:
            SentInspectorView(inspection: inspection)
        case .journal:
            JournalInspectorView(
                inspection: inspection,
                canSelectTurn: canSelectTurn,
                onSelectTurn: onSelectTurn
            )
        case .response:
            ResponseInspectorView(inspection: inspection)
        case .tools:
            EmptyView()
        }
    }
}

/// A compact empty state sized for the narrow inspector column, where
/// `ContentUnavailableView`'s large title wraps awkwardly.
struct InspectorEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    init(_ title: String, systemImage: String, detail: String) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
