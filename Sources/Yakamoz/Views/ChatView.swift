import Logging
import SwiftData
import SwiftUI
import YakamozCore

/// Owns the per-conversation `ChatViewModel`, built from the environment runtime and
/// `conversation.id` — the same `UUID` used as the PositronicKit `timelineId`
/// (see `ConversationCoordinator`).
struct ChatView: View {
    @Bindable var conversation: ConversationModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.yakamozRuntime) private var runtime
    @Environment(\.uiCoordinator) private var coordinator
    @Environment(\.terminalApprover) private var terminalApprover
    @Environment(\.toolApprover) private var toolApprover
    @Environment(\.providerStatus) private var providerStatus
    @Environment(\.providerSettings) private var providerSettings

    @State private var viewModel: ChatViewModel?
    @State private var inspectionViewModel: InspectionViewModel?
    @State private var draft = ""
    @State private var composerFocusToken = 0
    /// SID-2: section-title navigation chips for the current conversation, fetched from
    /// `TimelineAnnotationModel` rows. Refreshed on conversation switch and after each
    /// turn completes (so a newly-accepted section title surfaces as a chip without a
    /// manual reload). Empty for conversations that haven't shifted phases.
    @State private var sectionAnnotations: [SectionAnnotationView] = []

    /// Tracks whether the conversation scroll view is currently pinned near the
    /// bottom, so mid-stream autoscroll only follows the growing assistant bubble
    /// when the user is already riding along the bottom (not scrolled up to read
    /// history). Updated from `onScrollGeometryChange` on the transcript
    /// `ScrollView`; force-set to `true` whenever a new turn snaps to bottom.
    @State private var isStickyToBottom = true

    /// UIX-14: counts programmatic scrolls we've initiated that haven't yet "settled"
    /// (i.e. we haven't seen a subsequent `onScrollGeometryChange` reading since
    /// triggering them). While `> 0`, an off-bottom distance reading is *not* treated as
    /// evidence of a user scroll — see `ScrollFollowPresentation.shouldUnpin`. This is
    /// the fix for the leading UIX-14 hypothesis: content growing after a `scrollTo` (or
    /// that scroll landing short on a still-laying-out `LazyVStack` item) pushes the
    /// distance-to-bottom past the 80pt threshold with zero user input, and a plain
    /// distance check can't tell that apart from an actual scroll-up. A settle timer
    /// (rather than waiting indefinitely for a geometry callback that may not fire if
    /// nothing moves) bounds how long we suppress unpinning after each programmatic
    /// scroll.
    @State private var pendingProgrammaticScrollCount = 0

    /// UIX-14 suspect 3: a stable id to `scrollTo` instead of the last transcript item's
    /// id. Anchoring to the last *item* while that item is still mid-layout (its height
    /// growing as markdown/tool rows render) can land short of the true bottom; a
    /// dedicated zero-height sentinel after the `LazyVStack` always represents "the very
    /// bottom of the content" regardless of what's above it.
    private let scrollBottomSentinelId = "scroll-bottom-sentinel"

    @SceneStorage("inspector.isOpen") private var isInspectorOpen = true
    @SceneStorage("inspector.tab") private var selectedInspectorTabRaw = "prompt"

    @Query private var workspaces: [WorkspaceModel]
    @Query private var agents: [AgentModel]

    /// Resolves the assigned operator's persisted instructions.
    private var resolvedSystemInstructions: String? {
        guard let id = conversation.agentId else { return nil }
        return agents.first(where: { $0.id == id })?.instructions
    }

    /// Ordered filesystem roots for the active operator: its private vault first, followed by
    /// attached folder workspaces. Each root remains jailed independently by YakamozRuntime.
    private var operatorWorkspaceRoots: [URL] {
        var roots: [URL] = []
        if let id = conversation.agentId,
           let vaultPath = agents.first(where: { $0.id == id })?.vaultPath,
           !vaultPath.isEmpty
        {
            roots.append(URL(fileURLWithPath: vaultPath, isDirectory: true))
        }
        roots.append(contentsOf: attachedFolderWorkspaces.map {
            URL(fileURLWithPath: $0.folderPath, isDirectory: true)
        })
        return roots
    }

    private var attachedWorkspacesList: [WorkspaceModel] {
        WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: workspaces)
    }

    /// Attached folder workspaces only (drives the filesystem tools' jail root and the
    /// Workspace inspector presentation).
    private var attachedFolderWorkspaces: [WorkspaceModel] {
        attachedWorkspacesList.filter { $0.kind == .folder }
    }

    /// Attached terminal workspaces only (each becomes a `TerminalToolContext` so the runtime
    /// builds that terminal's five tools).
    private var attachedTerminalWorkspaces: [WorkspaceModel] {
        attachedWorkspacesList.filter { $0.kind == .terminal }
    }

    private var hasFolderWorkspace: Bool {
        !attachedFolderWorkspaces.isEmpty
    }

    private var hasTerminalWorkspace: Bool {
        !attachedTerminalWorkspaces.isEmpty
    }

    private var folderWorkspace: FolderToolContext? {
        attachedFolderWorkspaces.first.map {
            FolderToolContext(workspaceID: $0.id, rootURL: URL(fileURLWithPath: $0.folderPath))
        }
    }

    private var terminalContexts: [TerminalToolContext] {
        attachedTerminalWorkspaces.map {
            TerminalToolContext(workspaceId: $0.id, rootURL: URL(fileURLWithPath: $0.folderPath))
        }
    }

    private var availableInspectorTools: [ConversationToolOption] {
        ConversationToolSupport.toolOptions(hasWorkspace: hasFolderWorkspace, hasTerminal: hasTerminalWorkspace)
    }

    private var effectiveEnabledToolIds: Set<String> {
        ConversationToolSupport.effectiveEnabledToolIDs(
            conversation.enabledToolIds,
            hasWorkspace: hasFolderWorkspace,
            hasTerminal: hasTerminalWorkspace
        )
    }

    /// A composite key over every attached workspace's id (in `allAttachedWorkspaceIds` order),
    /// joined into a single string. Used as a `.task(id:)`/sync key so views invalidate when
    /// ANY attached workspace changes — not just the first — since attaching/detaching a
    /// non-first workspace still affects available tools and (eventually) presentation.
    private var workspaceAttachmentKey: String {
        conversation.allAttachedWorkspaceIds.map(\.uuidString).joined(separator: ",")
    }

    var body: some View {
        Group {
            if let viewModel {
                chatBody(viewModel: viewModel)
            } else {
                ContentUnavailableView(
                    "Runtime Unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .navigationTitle(conversation.title)
        .toolbar {
            // docs/design/interaction-paradigm.md §3.3: the conversation's whole setup,
            // each control labelled with its current state.
            ToolbarItemGroup(placement: .primaryAction) {
                ConversationOperatorMenu(conversation: conversation)
                ConversationWorkspacesMenu(conversation: conversation)
                ConversationToolsMenu(
                    conversation: conversation,
                    availableTools: availableInspectorTools,
                    enabledToolIds: effectiveEnabledToolIds,
                    onSetToolEnabled: setToolEnabled
                )
                if let providerStatus, let providerSettings {
                    ProviderControlMenu(status: providerStatus, settings: providerSettings)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy) { isInspectorOpen.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help(isInspectorOpen ? "Hide inspector (⌘I)" : "Show inspector (⌘I)")
                .accessibilityLabel(isInspectorOpen ? "Hide inspector" : "Show inspector")
            }
        }
        .inspector(isPresented: $isInspectorOpen) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 360, max: 640)
        }
        .task(id: conversation.id) {
            await buildViewModelIfNeeded()
        }
        .task(id: toolSyncKey) {
            await refreshViewModelTools()
        }
        // Rebuild the view model when persona/sidecar settings change, so the
        // next send uses the updated system instructions and sidecar wiring.
        .task(id: rebuildKey) {
            await buildViewModelIfNeeded()
        }
        // SID-2: refresh the section-title navigation chips after each turn completes,
        // so a newly-accepted section title surfaces as a chip without a manual reload.
        // Fires when `isSending` flips from `true` → `false` (turn finalized).
        .onChange(of: viewModel?.isSending ?? false) { _, isSending in
            if !isSending {
                Task { await refreshSectionAnnotations() }
            }
        }
        // Menu-bar / keyboard command intents (Command-I, Command-1…5).
        .onChange(of: coordinator.toggleInspectorToken) { _, _ in
            withAnimation(.snappy) { isInspectorOpen.toggle() }
        }
        .onChange(of: coordinator.inspectorTabRequest.token) { _, _ in
            // The inspector always shows its five tabs (ADR 0003), so ⌘1…⌘5 always apply.
            let tabs = ["prompt", "sent", "journal", "response", "tools"]
            let index = coordinator.inspectorTabRequest.index
            guard tabs.indices.contains(index) else { return }
            selectedInspectorTabRaw = tabs[index]
            if !isInspectorOpen {
                withAnimation(.snappy) { isInspectorOpen = true }
            }
        }
        .onChange(of: coordinator.focusComposerToken) { _, _ in
            composerFocusToken += 1
        }
        // STAB-11: window close / navigating to no selection removes this `ChatView`
        // from the tree. That path doesn't go through `buildViewModelIfNeeded`, so the
        // replacement-site cancel there doesn't cover it; without this hook an in-flight
        // `sendTask` would keep running (retained by the runtime) until the stream ends
        // on its own. `cancel()` is idempotent, so overlapping with the rebuild path is
        // a harmless no-op. In a `NavigationSplitView` detail this view keeps its identity
        // across conversation switches (no recreate), so `onDisappear` only fires on
        // actual removal — not on switching between conversations.
        .onDisappear {
            viewModel?.cancel()
        }
    }

    /// A composite key over the settings that influence how the `ChatViewModel` is built.
    /// Changing any of them re-triggers `buildViewModelIfNeeded`.
    private var rebuildKey: String {
        "\(conversation.agentId?.uuidString ?? "-")|\(conversation.sidecarDirectivesEnabled)"
    }

    /// Tracks the conversation state that affects which tools the view model should
    /// offer on its next send.
    private var toolSyncKey: String {
        let enabledToolIds = conversation.enabledToolIds.sorted().joined(separator: ",")
        return "\(workspaceAttachmentKey)|\(enabledToolIds)"
    }

    private func chatBody(viewModel: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            if let terminalApprover {
                TerminalApprovalBanner(
                    approver: terminalApprover,
                    workspaceIDs: Set(attachedTerminalWorkspaces.map(\.id))
                )
            }

            if let toolApprover {
                ToolApprovalBanner(approver: toolApprover)
            }

            conversationStack(viewModel: viewModel)
                .onChange(of: viewModel.inspectedInspectionTurnIndex, initial: true) { _, newIndex in
                    Task { await inspectionViewModel?.select(conversationId: conversation.id, turnIndex: newIndex) }
                }

            Divider()

            ComposerView(
                text: $draft,
                isSending: viewModel.isSending,
                onSend: { send(viewModel: viewModel) },
                onCancel: { viewModel.cancel() },
                focusToken: composerFocusToken,
                isDisabled: AgentSidebarPresentation.isSendDisabled(agentId: conversation.agentId),
                disabledReason: "Assign an operator before sending."
            )
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let viewModel, let inspectionViewModel {
            TurnInspector(
                viewModel: inspectionViewModel,
                turnState: viewModel.inspectedTurnState,
                isFollowingLatest: viewModel.isInspectingLatest,
                onFollowLatest: { viewModel.selectTurn(nil) },
                selectedTabRaw: $selectedInspectorTabRaw,
                canSelectTurn: { viewModel.canSelectInspectionTurn($0) },
                onSelectTurn: { viewModel.selectInspectionTurn($0) }
            )
        } else {
            ContentUnavailableView("Inspector Unavailable", systemImage: "sidebar.trailing")
        }
    }

    /// Selecting a reply pins the inspector to it (opening the inspector if needed);
    /// deselecting returns the inspector to following the latest turn.
    private func selectTurn(_ turnIndex: Int?, in viewModel: ChatViewModel) {
        viewModel.selectTurn(turnIndex)
        if turnIndex != nil, !isInspectorOpen {
            withAnimation(.snappy) { isInspectorOpen = true }
        }
    }

    /// Shown in place of the transcript until the first message: who you're talking to and,
    /// when nothing is attached, the workspace suggestion that used to be injected into the
    /// transcript as a prompt row.
    private var emptyConversation: some View {
        let operatorName = conversation.agentId.flatMap { id in agents.first { $0.id == id }?.name }
        return ContentUnavailableView {
            Label(
                operatorName.map { "Talk to \($0)" } ?? "No Operator",
                systemImage: operatorName == nil ? "person.crop.circle.badge.questionmark" : "bubble.left.and.bubble.right"
            )
        } description: {
            if operatorName == nil {
                Text("Choose an operator from the toolbar to start this conversation.")
            } else if conversation.allAttachedWorkspaceIds.isEmpty {
                Text("Attach a folder to let the operator read files, or just start typing.")
            } else {
                Text("Send a message to start. Select a reply to inspect how its prompt was built.")
            }
        } actions: {
            if operatorName != nil, conversation.allAttachedWorkspaceIds.isEmpty {
                Button("Attach Folder…") {
                    WorkspaceActions.pickFolder(for: conversation, modelContext: modelContext)
                }
            }
        }
    }

    /// A single combined growth metric for the last assistant transcript item — UIX-8
    /// broadens this beyond plain reconstructed-text length (`ScrollFollowPresentation
    /// .streamingGrowthMetric`) so the mid-stream follow keeps re-triggering during
    /// thinking-only or tool-only stretches, where text length alone would stall.
    ///
    /// This still mutates monotonically per streamed token/thinking-delta/segment —
    /// `ChatViewModel.consume` appends a `.assistant(id:turn:)` item once per turn and
    /// then mutates that same `ChatTurnState` in place via `updateAssistantItem`
    /// (rewriting the transcript element in place), so the metric grows without ever
    /// touching the item's id.
    private func lastAssistantStreamingGrowthMetric(viewModel: ChatViewModel) -> Int {
        guard case let .assistant(_, turn) = viewModel.transcript.last else { return 0 }
        return ScrollFollowPresentation.streamingGrowthMetric(
            reconstructedTextCount: turn.response.reconstructedText.count,
            thinkingCount: turn.response.thinking.count,
            segmentCount: turn.turnSegments.count
        )
    }

    /// `true` when the last transcript item is an assistant turn that has not
    /// yet reached its terminal state (`turn.isComplete == false`), i.e. it is
    /// still accumulating streamed tokens / tool activity.
    private func isLastAssistantTurnStreaming(viewModel: ChatViewModel) -> Bool {
        guard case let .assistant(_, turn) = viewModel.transcript.last else { return false }
        return !turn.isComplete
    }

    @ViewBuilder
    private func conversationStack(viewModel: ChatViewModel) -> some View {
        if viewModel.transcript.isEmpty {
            emptyConversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcriptStack(viewModel: viewModel)
        }
    }

    private func transcriptStack(viewModel: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            // SID-2: section-title navigation chips. Tapping a chip selects the turn
            // it anchors to in the transcript (reusing `viewModel.selectTurn`, the same
            // seam the existing turn-selection UI uses).
            SectionNavigationBar(
                annotations: sectionAnnotations,
                onSelect: { turnIndex in selectTurn(turnIndex, in: viewModel) }
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.transcript) { item in
                            MessageBubble(
                                item: item,
                                isSelected: isSelected(item, viewModel: viewModel),
                                onSelectTurn: { selectTurn($0, in: viewModel) },
                                onSelectPromptOption: handlePromptSelection,
                                onRetry: { viewModel.retryFailedTurn(errorId: $0) }
                            )
                            .id(item.id)
                        }
                        // UIX-14 suspect 3: a stable, always-present sentinel to scroll
                        // to instead of the last transcript item's own id. The last
                        // item's height can still be growing mid-layout (markdown
                        // re-parse, image/code-block layout) when `scrollTo` runs,
                        // which can land short of the true bottom; this zero-height
                        // marker is always positioned at the actual bottom of the
                        // `LazyVStack`'s content.
                        Color.clear
                            .frame(height: 0)
                            .id(scrollBottomSentinelId)
                    }
                    .padding()
                }
                .onScrollGeometryChange(for: ScrollFollowState.self) { geo in
                    // Within ~80pt of the bottom counts as "sticky", so the
                    // mid-stream follow only runs when the user is already
                    // riding along the bottom — not after they scroll up.
                    ScrollFollowState(
                        isAtBottom: geo.contentSize.height - geo.containerSize.height - geo.contentOffset.y <= 80,
                        contentHeight: geo.contentSize.height
                    )
                } action: { oldValue, newValue in
                    // UIX-14/UIX-16: a distance reading alone can't tell "the user
                    // scrolled up" apart from "content outgrew the last programmatic
                    // scroll, or that scroll landed short" — both present as
                    // isAtBottom == false. `ScrollFollowPresentation.shouldUnpin`
                    // suppresses unpinning both while a programmatic scroll is in
                    // flight (UIX-14) and when the contentSize grew since the last
                    // reading (UIX-16: streaming deltas pushing the bottom edge away).
                    // Re-pinning (isAtBottom == true) is always honored immediately.
                    if newValue.isAtBottom {
                        isStickyToBottom = true
                    } else if ScrollFollowPresentation.shouldUnpin(
                        currentState: newValue,
                        previousState: oldValue,
                        isProgrammaticScrollInFlight: pendingProgrammaticScrollCount > 0
                    ) {
                        isStickyToBottom = false
                    }
                }
                .onChange(of: viewModel.transcript.last?.id) { _, newId in
                    // UIX-8: a new transcript item (new assistant turn, error row,
                    // prompt row) never force-pins — it only autoscrolls when the
                    // user is already pinned to the bottom. Explicit re-pinning
                    // happens only from the user's own send action (see `send(
                    // viewModel:)` below), not from arbitrary content growth.
                    guard newId != nil else { return }
                    guard ScrollFollowPresentation.shouldFollowNewItem(isPinnedToBottom: isStickyToBottom) else { return }
                    followToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: lastAssistantStreamingGrowthMetric(viewModel: viewModel)) { oldMetric, newMetric in
                    // STAB-10: the streaming assistant turn reuses one
                    // `TranscriptItem` id for its whole lifetime, so the
                    // `.onChange(of: last?.id)` above fires only when the
                    // bubble first appears. To follow mid-stream content
                    // growth, also observe a combined growth metric (UIX-8:
                    // reconstructed text + thinking + segment count, so
                    // thinking-only/tool-only stretches still register) for
                    // the last assistant turn and re-scroll to it per change
                    // — but only while that turn is still streaming and the
                    // user is pinned to the bottom.
                    guard newMetric > oldMetric else { return }
                    guard ScrollFollowPresentation.shouldFollowStreamingGrowth(
                        isPinnedToBottom: isStickyToBottom,
                        isLastTurnStreaming: isLastAssistantTurnStreaming(viewModel: viewModel)
                    ) else { return }
                    // UIX-14 suspect 4: an animated `scrollTo` on every delta can race
                    // with the next one (each new delta cancels/restarts the previous
                    // animation), which contributed to landing short. Mid-stream
                    // follows are frequent (per-token), so keep them unanimated —
                    // animation is reserved for discrete jumps (new item arriving,
                    // the jump-to-bottom button).
                    followToBottom(proxy: proxy, animated: false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if ScrollFollowPresentation.shouldShowJumpToBottomButton(isPinnedToBottom: isStickyToBottom) {
                        JumpToBottomButton {
                            isStickyToBottom = true
                            followToBottom(proxy: proxy, animated: true)
                        }
                        .padding(16)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isStickyToBottom)
            }
        }
    }

    /// Scrolls to `scrollBottomSentinelId` (UIX-14 suspect 3's stable bottom marker,
    /// rather than the last item's own id) and marks a programmatic scroll "in flight"
    /// for a short settle window, during which `onScrollGeometryChange` readings are not
    /// allowed to unpin (UIX-14 fix — see `pendingProgrammaticScrollCount` and
    /// `ScrollFollowPresentation.shouldUnpin`). `animated` is `false` for frequent
    /// mid-stream follows (suspect 4: avoid animation races on every delta) and `true`
    /// for discrete jumps (new item arriving, the jump-to-bottom button).
    private func followToBottom(proxy: ScrollViewProxy, animated: Bool) {
        pendingProgrammaticScrollCount += 1
        let scroll = { proxy.scrollTo(scrollBottomSentinelId, anchor: .bottom) }
        if animated {
            withAnimation { scroll() }
        } else {
            scroll()
        }
        // Bound how long we suppress unpinning after this scroll: long enough for the
        // scroll (and any animation) to settle and produce a fresh geometry reading,
        // short enough that a genuine user scroll-up right after is still caught
        // promptly (UIX-14 acceptance criterion).
        Task {
            try? await Task.sleep(for: .milliseconds(animated ? 250 : 100))
            pendingProgrammaticScrollCount = max(0, pendingProgrammaticScrollCount - 1)
        }
    }

    private func isSelected(_ item: TranscriptItem, viewModel: ChatViewModel) -> Bool {
        guard case let .assistant(_, turn) = item else { return false }
        return viewModel.selectedTurnIndex == turn.turnIndex
    }

    private func send(viewModel: ChatViewModel) {
        let text = draft
        draft = ""
        // UIX-8: sending is the one deliberate exception to "content events never
        // force-pin" — the user's own action implies intent to follow the reply, so
        // explicitly re-pin here. The new user-message transcript item that `send`
        // appends then trips `.onChange(of: transcript.last?.id)` in
        // `conversationStack`, which now sees `isStickyToBottom == true` and scrolls.
        isStickyToBottom = true
        viewModel.send(text)
        // Return keyboard focus to the composer so the user can keep typing without
        // reaching for the mouse.
        composerFocusToken += 1
    }

    private func buildViewModelIfNeeded() async {
        guard let runtime else { return }
        // STAB-11: this rebuild replaces `viewModel` with a fresh instance (loaded from
        // the persisted transcript) on conversation switch, persona/sidecar toggle,
        // and workspace attach/detach. None of those previously cancelled the
        // outgoing view model's in-flight `sendTask`, so a stream mid-turn kept running
        // invisibly — retained by the concurrency runtime (and by `consume`'s strong-`self`
        // dispatch) even after `viewModel = chat` dropped the only `@State` reference —
        // continuing to consume the ChatEngine pipeline and persist via the inspector.
        // Cancel the outgoing model first so its turn finalizes as cancelled and the
        // task can release it. `cancel()` is idempotent, so this is safe when nothing is
        // in flight and safe to run again from `.onDisappear` on window close.
        viewModel?.cancel()
        // SID-2: feed the last accepted section-title annotation as the "current section"
        // context for the upcoming turn's `section_title` directive (mirrors SID-1's
        // current-title feed). Fetched via the runtime so the app target does not need
        // to construct a `ConversationCoordinator` (which would name
        // `ThreadPersistenceProtocol`, a PositronicKit type the app target must not
        // import per the architecture boundary).
        let currentSectionTitle = await runtime.fetchCurrentSectionTitle(conversationId: conversation.id)
        let chat = await runtime.makeChatViewModel(
            timelineId: conversation.id,
            systemInstructions: resolvedSystemInstructions,
            enabledToolIds: conversation.enabledToolIds,
            workspaceRoots: operatorWorkspaceRoots,
            terminals: terminalContexts,
            sidecarDirectivesEnabled: conversation.sidecarDirectivesEnabled,
            // SID-1 cadence state: treat the conversation as "untitled" until the
            // title directive has actually returned a non-null value, so a manually
            // set initial title (e.g. "New Conversation") is not mistaken for the model's
            // current title for comparison. `hasReceivedTitleDirective` flips on the
            // first accepted title directive; only then do we feed `conversation.title`.
            conversationTitle: conversation.hasReceivedTitleDirective ? conversation.title : nil,
            turnsSinceLastTitleDirective: conversation.turnsSinceLastTitleDirective,
            // SID-2: the current section title (or nil if no section has been marked yet).
            currentSectionTitle: currentSectionTitle,
            onTimelineStateChange: { [conversation, modelContext] state in
                guard conversation.timelineState != state else { return }
                conversation.timelineState = state
                conversation.timelineStateUpdatedAt = .now
                do {
                    try modelContext.save()
                } catch {
                    Log.appError("failed to save conversation state change", metadata: [
                        "conversationID": "\(conversation.id)",
                    ])
                }
            }
        )
        let inspection = runtime.makeInspectionViewModel()
        viewModel = chat
        inspectionViewModel = inspection
        await inspection.select(conversationId: conversation.id, turnIndex: chat.inspectedInspectionTurnIndex)
        await refreshSectionAnnotations()
    }

    /// SID-2: refreshes the section-title navigation chips from persisted
    /// `TimelineAnnotationModel` rows. Called on conversation switch and after each
    /// turn completes so a newly-accepted section title surfaces as a chip without a
    /// manual reload. Errors are swallowed (an empty chip list degrades gracefully —
    /// the bar simply hides).
    private func refreshSectionAnnotations() async {
        guard let runtime else {
            sectionAnnotations = []
            return
        }
        sectionAnnotations = await runtime.fetchSectionAnnotations(conversationId: conversation.id)
    }

    private func refreshViewModelTools() async {
        guard let runtime, let viewModel else { return }
        let tools = await runtime.resolveTools(
            enabledToolIds: conversation.enabledToolIds,
            workspaceRoots: operatorWorkspaceRoots,
            terminals: terminalContexts
        )
        viewModel.updateTools(tools)
    }

    /// Transcript prompt rows are dismissed when answered; nothing in this view presents
    /// one anymore (the workspace suggestion moved to the empty state).
    private func handlePromptSelection(promptId: UUID, option _: ChatPromptOption) {
        viewModel?.dismissTranscriptItem(id: promptId)
    }

    private func setToolEnabled(id: String, isEnabled: Bool) {
        var selected = effectiveEnabledToolIds
        if isEnabled {
            selected.insert(id)
        } else {
            guard selected.count > 1 else { return }
            selected.remove(id)
        }
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(
            selected,
            hasWorkspace: hasFolderWorkspace,
            hasTerminal: hasTerminalWorkspace
        )
        do {
            try modelContext.save()
        } catch {
            Log.appError("failed to save enabled tool settings", metadata: [
                "conversationID": "\(conversation.id)",
                "toolID": id,
            ])
        }
    }
}

/// UIX-8: floating affordance shown over the transcript when the user has scrolled up
/// (unpinned from the bottom) — tapping it jumps to the latest content and re-enables
/// following. Hidden while pinned (`ScrollFollowPresentation.shouldShowJumpToBottomButton`
/// drives visibility from the call site).
private struct JumpToBottomButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .shadow(radius: 3, y: 1)
        .accessibilityLabel("Jump to bottom")
    }
}
