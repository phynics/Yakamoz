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
    @State private var workspacePresentation: WorkspacePresentation?
    @State private var workspacePromptId: UUID?
    @State private var dismissedWorkspacePromptConversationId: UUID?
    @State private var composerFocusToken = 0

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
    @Query private var customPersonas: [PersonaModel]

    /// Resolves the conversation's `personaSlug` to system instructions: a built-in persona's
    /// instructions, a custom `PersonaModel`'s instructions, or `nil` for the default persona.
    private var resolvedSystemInstructions: String? {
        guard let slug = conversation.personaSlug else { return nil }
        if let builtIn = PersonaCatalog.builtIn(id: slug) { return builtIn.instructions }
        if let custom = customPersonas.first(where: { $0.id.uuidString == slug }) {
            return custom.systemInstructions
        }
        return nil
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

    private var workspaceRoot: URL? {
        attachedFolderWorkspaces.first.map { URL(fileURLWithPath: $0.folderPath) }
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
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.snappy) { isInspectorOpen.toggle() }
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help(isInspectorOpen ? "Hide inspector (⌘I)" : "Show inspector (⌘I)")
                .accessibilityLabel(isInspectorOpen ? "Hide inspector" : "Show inspector")
            }

            ToolbarItem(placement: .automatic) {
                PersonaPicker(conversation: conversation)
            }

            ToolbarItem(placement: .automatic) {
                TypedReplyControls(conversation: conversation)
            }

            // UIX-3 review fix #2: `ProviderControlMenu` used to live in the toolbar, but
            // Compose mode (InspectorDrawer's default, no-turn-selected pane) now owns
            // next-turn controls including the provider menu — rendering it here too was a
            // duplicate control. Compose mode is the single place it renders now.
        }
        .task(id: conversation.id) {
            await buildViewModelIfNeeded()
        }
        .task(id: workspaceAttachmentKey) {
            await refreshWorkspacePresentation()
        }
        .task(id: toolSyncKey) {
            await refreshViewModelTools()
        }
        // Rebuild the view model when persona/typed-reply/follow-up settings change, so the
        // next send uses the updated system instructions, schema, and plugin wiring.
        .task(id: rebuildKey) {
            await buildViewModelIfNeeded()
        }
        // Menu-bar / keyboard command intents (Command-I, Command-1…6).
        .onChange(of: coordinator.toggleInspectorToken) { _, _ in
            withAnimation(.snappy) { isInspectorOpen.toggle() }
        }
        .onChange(of: coordinator.inspectorTabRequest.token) { _, _ in
            // UIX-3 review fix #3: Command-1…5 select a per-turn Inspect tab, but Compose
            // mode (no turn selected) has no tabs to select — applying the request there
            // silently did nothing. Only act on the request when a turn is actually
            // selected, so the shortcut is a deliberate no-op rather than a silent one.
            guard viewModel?.selectedInspectionTurnIndex != nil else { return }
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
        "\(conversation.personaSlug ?? "-")|\(conversation.typedReplyEnabled)|\(conversation.autonomousFollowUpEnabled)"
    }

    /// Tracks the conversation state that affects which tools the view model should
    /// offer on its next send.
    private var toolSyncKey: String {
        let enabledToolIds = conversation.enabledToolIds.sorted().joined(separator: ",")
        return "\(workspaceAttachmentKey)|\(enabledToolIds)"
    }

    private func chatBody(viewModel: ChatViewModel) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
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
                        .onChange(of: viewModel.selectedInspectionTurnIndex) { _, newIndex in
                            Task { await inspectionViewModel?.select(conversationId: conversation.id, turnIndex: newIndex) }
                            if newIndex != nil, !isInspectorOpen {
                                withAnimation(.snappy) { isInspectorOpen = true }
                            }
                        }

                    Divider()

                    ComposerView(
                        text: $draft,
                        isSending: viewModel.isSending,
                        onSend: { send(viewModel: viewModel) },
                        onCancel: { viewModel.cancel() },
                        focusToken: composerFocusToken
                    )
                }

                if let inspectionViewModel {
                    InspectorDrawer(
                        viewModel: inspectionViewModel,
                        detailWidth: proxy.size.width,
                        selectedTurnState: viewModel.selectedTurnState,
                        workspacePresentation: workspacePresentation,
                        providerStatus: providerStatus,
                        providerSettings: providerSettings,
                        availableTools: availableInspectorTools,
                        enabledToolIds: effectiveEnabledToolIds,
                        onRefreshWorkspace: { Task { await refreshWorkspacePresentation() } },
                        onAttachDocuments: attachDefaultWorkspace,
                        onChooseWorkspace: pickFolderForPrompt,
                        onDetachWorkspace: detachWorkspace,
                        onSetToolEnabled: setToolEnabled,
                        onCreateTerminal: pickFolderForTerminal,
                        selectedInspectionTurnIndex: viewModel.selectedInspectionTurnIndex,
                        onCloseInspection: { viewModel.selectInspectionTurn(nil) },
                        isOpen: $isInspectorOpen,
                        selectedTabRaw: $selectedInspectorTabRaw,
                        canSelectTurn: { viewModel.canSelectInspectionTurn($0) },
                        onSelectTurn: { viewModel.selectInspectionTurn($0) }
                    )
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

    private func conversationStack(viewModel: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.transcript) { item in
                            MessageBubble(
                                item: item,
                                isSelected: isSelected(item, viewModel: viewModel),
                                onSelectTurn: { viewModel.selectTurn($0) },
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
                .onScrollGeometryChange(for: Bool.self) { geo in
                    // Within ~80pt of the bottom counts as "sticky", so the
                    // mid-stream follow only runs when the user is already
                    // riding along the bottom — not after they scroll up.
                    geo.contentSize.height - geo.containerSize.height - geo.contentOffset.y <= 80
                } action: { _, isAtBottom in
                    // UIX-14: a distance reading alone can't tell "the user scrolled
                    // up" apart from "content outgrew the last programmatic scroll, or
                    // that scroll landed short" — both present as isAtBottom == false.
                    // Only let this reading unpin when we're not still waiting to see
                    // where a programmatic scroll we triggered actually settles;
                    // re-pinning (isAtBottom == true) is always honored immediately.
                    if isAtBottom {
                        isStickyToBottom = true
                    } else if ScrollFollowPresentation.shouldUnpin(
                        isAtBottom: isAtBottom,
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
        // the persisted transcript) on conversation switch, persona/typed-reply/follow-up
        // toggle, and workspace attach/detach. None of those previously cancelled the
        // outgoing view model's in-flight `sendTask`, so a stream mid-turn kept running
        // invisibly — retained by the concurrency runtime (and by `consume`'s strong-`self`
        // dispatch) even after `viewModel = chat` dropped the only `@State` reference —
        // continuing to consume the ChatEngine pipeline and persist via the inspector.
        // Cancel the outgoing model first so its turn finalizes as cancelled and the
        // task can release it. `cancel()` is idempotent, so this is safe when nothing is
        // in flight and safe to run again from `.onDisappear` on window close.
        viewModel?.cancel()
        workspacePromptId = nil
        // Idempotent backfill: move legacy single-workspace attachment into the array on rebuild.
        WorkspaceAttachmentSupport.backfillLegacyAttachment(conversation)
        let chat = await runtime.makeChatViewModel(
            timelineId: conversation.id,
            systemInstructions: resolvedSystemInstructions,
            enabledToolIds: conversation.enabledToolIds,
            workspaceRoot: workspaceRoot,
            terminals: terminalContexts,
            typedReplyEnabled: conversation.typedReplyEnabled,
            autonomousFollowUpEnabled: conversation.autonomousFollowUpEnabled,
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
        let inspection = await runtime.makeInspectionViewModel()
        viewModel = chat
        inspectionViewModel = inspection
        await inspection.select(conversationId: conversation.id, turnIndex: chat.selectedInspectionTurnIndex)
        await refreshWorkspacePresentation()
        offerWorkspacePromptIfNeeded(in: chat)
    }

    /// Rebuilds the Workspace-tab presentation from the conversation's first attached folder
    /// workspace (or clears it when none is attached). Runs on conversation open and
    /// whenever `workspaceAttachmentKey` changes (i.e. any attached workspace is added or
    /// removed, not just the first).
    private func refreshWorkspacePresentation() async {
        guard let runtime, let workspace = attachedFolderWorkspaces.first else {
            workspacePresentation = nil
            return
        }
        // Extract Sendable values on the MainActor; never send the @Model across the boundary.
        let folderPath = workspace.folderPath
        let displayName = workspace.displayName
        workspacePresentation = await runtime.makeWorkspacePresentation(folderPath: folderPath, displayName: displayName)
    }

    private func refreshViewModelTools() async {
        guard let runtime, let viewModel else { return }
        let tools = runtime.resolveTools(
            enabledToolIds: conversation.enabledToolIds,
            workspaceRoot: workspaceRoot,
            terminals: terminalContexts
        )
        viewModel.updateTools(tools)
    }

    private func offerWorkspacePromptIfNeeded(in viewModel: ChatViewModel) {
        guard conversation.allAttachedWorkspaceIds.isEmpty else { return }
        guard dismissedWorkspacePromptConversationId != conversation.id else { return }
        guard workspacePromptId == nil else { return }
        guard viewModel.transcript.allSatisfy({ item in
            if case .prompt = item { return true }
            return false
        }) else { return }

        workspacePromptId = viewModel.presentPrompt(ChatPrompt(
            title: "Attach a folder?",
            detail: "Use it as this chat's workspace.",
            options: [
                ChatPromptOption(id: "documents", title: "Documents", systemImage: "folder"),
                ChatPromptOption(id: "choose", title: "Choose Folder", systemImage: "folder.badge.plus"),
                ChatPromptOption(id: "skip", title: "Skip", systemImage: "xmark"),
            ]
        ))
    }

    private func handlePromptSelection(promptId: UUID, option: ChatPromptOption) {
        viewModel?.dismissTranscriptItem(id: promptId)
        if workspacePromptId == promptId {
            workspacePromptId = nil
            dismissedWorkspacePromptConversationId = conversation.id
        }

        switch option.id {
        case "documents":
            if let url = WorkspaceAttachmentSupport.defaultDocumentsURL {
                WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
                Task { await buildViewModelIfNeeded() }
            }
        case "choose":
            pickFolderForPrompt()
        default:
            break
        }
    }

    private func pickFolderForPrompt() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        panel.message = "Choose a folder to use as this conversation's workspace."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
        Task { await buildViewModelIfNeeded() }
    }

    private func pickFolderForTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Terminal"
        panel.message = """
        Choose a folder to be your terminal's starting directory.

        The terminal shell is NOT jailed to this folder; it can access any file on your system. \
        Each command is approval-gated unless you allow the terminal for the session.
        """

        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceAttachmentSupport.createTerminalFromFolderURL(url, for: conversation, modelContext: modelContext)
        Task { await buildViewModelIfNeeded() }
    }

    private func attachDefaultWorkspace() {
        guard let url = WorkspaceAttachmentSupport.defaultDocumentsURL else { return }
        WorkspaceAttachmentSupport.attachWorkspace(to: conversation, modelContext: modelContext, url: url)
        Task { await buildViewModelIfNeeded() }
    }

    /// Detaches the folder workspace currently shown in the inspector.
    ///
    /// The Workspace inspector presents only the first attached *folder* workspace
    /// (`attachedFolderWorkspaces.first`), so this detaches that same workspace explicitly
    /// by id, rather than relying on the legacy "first/legacy" heuristic in
    /// `WorkspaceAttachmentSupport.detachWorkspace(from:modelContext:)`.
    private func detachWorkspace() {
        guard let first = attachedFolderWorkspaces.first else { return }
        WorkspaceAttachmentSupport.detachWorkspace(id: first.id, from: conversation, modelContext: modelContext)
        Task { await buildViewModelIfNeeded() }
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
                .font(.system(size: 14, weight: .semibold))
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
