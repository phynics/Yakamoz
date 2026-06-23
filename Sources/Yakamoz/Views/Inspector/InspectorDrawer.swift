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

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .prompt: "Prompt"
        case .sent: "Sent"
        case .journal: "Journal"
        case .response: "Response"
        }
    }

    var systemImage: String {
        switch self {
        case .prompt: "text.alignleft"
        case .sent: "paperplane"
        case .journal: "book.closed"
        case .response: "bubble.left.and.bubble.right"
        }
    }
}

/// A resizable, Xcode-style bottom drawer that hosts the inspector tabs for the
/// currently-selected turn.
///
/// Layout: a divider with a drag handle on top, then a segmented tab picker, then the
/// selected tab's content. The drawer height is drag-resizable and clamped to
/// `180...(0.7 * detailHeight)`. Open state, selected tab, and height persist across
/// launches via `@SceneStorage`.
///
/// The drawer never owns turn selection: it renders whatever `viewModel.inspection`
/// currently holds. `ChatView` drives loading by calling `InspectionViewModel.select`
/// when the selected turn or conversation changes; toggling the drawer closed here does
/// not discard that selection.
struct InspectorDrawer: View {
    let viewModel: InspectionViewModel
    /// Height of the detail area the drawer lives in, used to clamp the max drawer height.
    let detailHeight: CGFloat

    @SceneStorage("inspector.isOpen") private var isOpen = false
    @SceneStorage("inspector.tab") private var selectedTabRaw = InspectorTab.prompt.rawValue
    @SceneStorage("inspector.height") private var storedHeight: Double = 280

    @State private var dragStartHeight: Double?

    /// Navigates to an adjacent turn within the same conversation. Wired by `ChatView`
    /// so the Journal tab's prev/next buttons reuse the same selection path as bubble taps.
    let onSelectTurn: (Int) -> Void

    private var selectedTab: InspectorTab {
        InspectorTab(rawValue: selectedTabRaw) ?? .prompt
    }

    private var minHeight: CGFloat {
        180
    }

    private var maxHeight: CGFloat {
        max(minHeight, detailHeight * 0.7)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if isOpen {
                drawer
                    .transition(.move(edge: .bottom))
            }
        }
        .overlay(alignment: .topTrailing) {
            toggleButton
                .padding(8)
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.snappy) { isOpen.toggle() }
        } label: {
            Image(systemName: "sidebar.bottom")
                .symbolVariant(isOpen ? .fill : .none)
        }
        .buttonStyle(.borderless)
        .help("Toggle inspector")
        .accessibilityLabel(isOpen ? "Hide inspector" : "Show inspector")
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            resizeHandle
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
        .frame(height: clampedHeight)
        .background(.bar)
    }

    private var clampedHeight: CGFloat {
        min(max(CGFloat(storedHeight), minHeight), maxHeight)
    }

    private var resizeHandle: some View {
        VStack(spacing: 2) {
            Divider()
            Capsule()
                .fill(.secondary)
                .frame(width: 36, height: 4)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? Double(clampedHeight)
                    if dragStartHeight == nil { dragStartHeight = start }
                    // Dragging up (negative translation) grows the drawer.
                    let proposed = start - Double(value.translation.height)
                    storedHeight = min(max(proposed, Double(minHeight)), Double(maxHeight))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .accessibilityLabel("Resize inspector")
        .accessibilityHint("Drag to change the inspector height")
    }

    @ViewBuilder
    private var tabContent: some View {
        if let inspection = viewModel.inspection {
            view(for: selectedTab, inspection: inspection)
        } else if let error = viewModel.loadError {
            ContentUnavailableView("Inspection Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView("No Turn Selected", systemImage: "cursorarrow.rays", description: Text("Select an assistant turn to inspect its prompt."))
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
            JournalInspectorView(inspection: inspection, onSelectTurn: onSelectTurn)
        case .response:
            ResponseInspectorView(inspection: inspection)
        }
    }

    private var tabBinding: Binding<InspectorTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabRaw = $0.rawValue }
        )
    }
}
