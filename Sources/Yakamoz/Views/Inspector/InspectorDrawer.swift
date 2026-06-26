import SwiftUI
import YakamozCore

/// One selectable tab in the inspector drawer. Extensible: CP9 will add `tools` and
/// `workspace` cases here and a matching `view(for:)` branch — no other call site needs
/// to change because the drawer iterates `InspectorTab.allCases`.
enum InspectorTab: String, CaseIterable, Identifiable {
    case prompt
    case sent
    case journal
    case response
    case tools
    case workspace

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
        case .workspace: "Workspace"
        }
    }

    var systemImage: String {
        switch self {
        case .prompt: "text.alignleft"
        case .sent: "paperplane"
        case .journal: "book.closed"
        case .response: "bubble.left.and.bubble.right"
        case .tools: "wrench.and.screwdriver"
        case .workspace: "folder"
        }
    }
}

/// A resizable, Xcode-style right inspector that hosts the tabs for the
/// currently-selected turn.
///
/// Layout: a leading resize handle, then a segmented tab picker, then the selected
/// tab's content. The panel width is drag-resizable and clamped to
/// `280...(0.55 * detailWidth)`. Open state, selected tab, and width persist across
/// launches via `@SceneStorage`.
///
/// The inspector never owns turn selection: it renders whatever `viewModel.inspection`
/// currently holds. `ChatView` drives loading by calling `InspectionViewModel.select`
/// when the selected turn or conversation changes; toggling the inspector closed here does
/// not discard that selection.
struct InspectorDrawer: View {
    let viewModel: InspectionViewModel
    /// Width of the detail area the inspector lives in, used to clamp the max panel width.
    let detailWidth: CGFloat

    /// The selected turn's live, in-memory tool-call state for the Tools tab (see
    /// `ToolsInspectorView`'s doc comment on why this is sourced from `ChatViewModel`
    /// rather than `InspectionPresentation`).
    let selectedTurnState: ChatTurnState?
    /// The conversation's attached folder workspace, if any, for the Workspace tab.
    let workspacePresentation: WorkspacePresentation?
    let availableTools: [ConversationToolOption]
    let enabledToolIds: Set<String>
    /// Re-fetches `workspacePresentation` (e.g. after files changed on disk).
    let onRefreshWorkspace: () -> Void
    let onAttachDocuments: () -> Void
    let onChooseWorkspace: () -> Void
    let onDetachWorkspace: () -> Void
    let onSetToolEnabled: (String, Bool) -> Void
    @Binding var isOpen: Bool
    /// The selected inspector tab's raw value, owned by `ChatView` (via `@SceneStorage`)
    /// so menu-bar commands (Command-1…6) can drive it. Bound here so the segmented picker
    /// stays the single source of truth either way.
    @Binding var selectedTabRaw: String

    @SceneStorage("inspector.width") private var storedWidth: Double = 360

    @State private var dragStartWidth: Double?

    /// Navigates to an adjacent turn within the same conversation. Wired by `ChatView`
    /// so the Journal tab's prev/next buttons reuse the same selection path as bubble taps.
    let canSelectTurn: (Int) -> Bool
    let onSelectTurn: (Int) -> Void

    private var selectedTab: InspectorTab {
        InspectorTab(rawValue: selectedTabRaw) ?? .prompt
    }

    private var minWidth: CGFloat {
        280
    }

    var body: some View {
        Group {
            if isOpen {
                drawer
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var drawer: some View {
        HStack(spacing: 0) {
            resizeHandle

            VStack(spacing: 0) {
                Picker("Inspector Tab", selection: tabBinding) {
                    ForEach(InspectorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: clampedWidth)
            .background(.bar)
        }
    }

    private var clampedWidth: CGFloat {
        min(max(CGFloat(storedWidth), minWidth), maxWidth)
    }

    private var resizeHandle: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(.secondary)
                .frame(width: 4, height: 36)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? Double(clampedWidth)
                    if dragStartWidth == nil { dragStartWidth = start }
                    let proposed = start - Double(value.translation.width)
                    storedWidth = min(max(proposed, Double(minWidth)), Double(maxWidth))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .accessibilityLabel("Resize inspector")
        .accessibilityHint("Drag to change the inspector width")
    }

    private var maxWidth: CGFloat {
        max(minWidth, detailWidth * 0.55)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .tools:
            ToolsInspectorView(
                persistedTools: viewModel.inspection?.response?.tools ?? [],
                liveTurn: selectedTurnState,
                availableTools: availableTools,
                enabledToolIds: enabledToolIds,
                onSetToolEnabled: onSetToolEnabled
            )
        case .workspace:
            WorkspaceInspectorView(
                presentation: workspacePresentation,
                touchedFiles: selectedTurnState?.workspaceFiles ?? [],
                onRefresh: onRefreshWorkspace,
                onAttachDocuments: onAttachDocuments,
                onChooseFolder: onChooseWorkspace,
                onDetach: onDetachWorkspace
            )
        case .prompt, .sent, .journal, .response:
            if let inspection = viewModel.inspection {
                view(for: selectedTab, inspection: inspection)
            } else if let error = viewModel.loadError {
                ContentUnavailableView("Inspection Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("No Turn Selected", systemImage: "cursorarrow.rays", description: Text("Select an assistant turn to inspect its prompt."))
            }
        }
    }

    @ViewBuilder
    private func view(for tab: InspectorTab, inspection: InspectionPresentation) -> some View {
        switch tab {
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
        case .tools, .workspace:
            EmptyView()
        }
    }

    private var tabBinding: Binding<InspectorTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabRaw = $0.rawValue }
        )
    }
}
