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

    @SceneStorage("inspector.isOpen") private var isInspectorOpen = false
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

            if let providerStatus, let settings = providerSettings {
                ToolbarItem(placement: .automatic) {
                    ProviderControlMenu(status: providerStatus, settings: settings)
                }
            }
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
            let tabs = ["prompt", "sent", "journal", "response", "tools", "workspace"]
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
                        availableTools: availableInspectorTools,
                        enabledToolIds: effectiveEnabledToolIds,
                        onRefreshWorkspace: { Task { await refreshWorkspacePresentation() } },
                        onAttachDocuments: attachDefaultWorkspace,
                        onChooseWorkspace: pickFolderForPrompt,
                        onDetachWorkspace: detachWorkspace,
                        onSetToolEnabled: setToolEnabled,
                        isOpen: $isInspectorOpen,
                        selectedTabRaw: $selectedInspectorTabRaw,
                        canSelectTurn: { viewModel.canSelectInspectionTurn($0) },
                        onSelectTurn: { viewModel.selectInspectionTurn($0) }
                    )
                }
            }
        }
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
                                onSelectPromptOption: handlePromptSelection
                            )
                            .id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.transcript.last?.id) { _, newId in
                    guard let newId else { return }
                    withAnimation {
                        proxy.scrollTo(newId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func isSelected(_ item: TranscriptItem, viewModel: ChatViewModel) -> Bool {
        guard case let .assistant(_, turn) = item else { return false }
        return viewModel.selectedTurnIndex == turn.turnIndex
    }

    private func send(viewModel: ChatViewModel) {
        let text = draft
        draft = ""
        viewModel.send(text)
        // Return keyboard focus to the composer so the user can keep typing without
        // reaching for the mouse.
        composerFocusToken += 1
    }

    private func buildViewModelIfNeeded() async {
        guard let runtime else { return }
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
