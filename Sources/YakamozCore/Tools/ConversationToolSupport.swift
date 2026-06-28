import Foundation
import SwiftData

public struct ConversationToolOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let requiresWorkspace: Bool
    /// Whether this option requires an attached *terminal* workspace (YAK-T4), distinct from
    /// `requiresWorkspace` which gates on a folder workspace.
    public let requiresTerminal: Bool

    public init(id: String, title: String, systemImage: String, requiresWorkspace: Bool, requiresTerminal: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.requiresWorkspace = requiresWorkspace
        self.requiresTerminal = requiresTerminal
    }
}

public enum ConversationToolSupport {
    public static let builtInToolOptions: [ConversationToolOption] = [
        ConversationToolOption(id: "calculator", title: "Calculator", systemImage: "plus.slash.minus", requiresWorkspace: false),
        ConversationToolOption(id: "current_datetime", title: "Current Date/Time", systemImage: "calendar.badge.clock", requiresWorkspace: false),
    ]

    public static var builtInToolIDs: [String] {
        builtInToolOptions.map(\.id)
    }

    /// The five terminal tool options (YAK-T4), offered only when a terminal workspace is
    /// attached. Their ids mirror `TerminalWorkspace.toolIds`.
    public static let terminalToolOptions: [ConversationToolOption] = [
        ConversationToolOption(id: "terminal_run", title: "Run Command", systemImage: "terminal", requiresWorkspace: false, requiresTerminal: true),
        ConversationToolOption(id: "terminal_read", title: "Read Output", systemImage: "text.alignleft", requiresWorkspace: false, requiresTerminal: true),
        ConversationToolOption(id: "terminal_send_input", title: "Send Input", systemImage: "keyboard", requiresWorkspace: false, requiresTerminal: true),
        ConversationToolOption(id: "terminal_interrupt", title: "Interrupt", systemImage: "stop.circle", requiresWorkspace: false, requiresTerminal: true),
        ConversationToolOption(id: "terminal_wait", title: "Wait", systemImage: "hourglass", requiresWorkspace: false, requiresTerminal: true),
    ]

    public static func toolOptions(hasWorkspace: Bool, hasTerminal: Bool = false) -> [ConversationToolOption] {
        let workspaceOptions = FileSystemWorkspace.toolIds.map {
            ConversationToolOption(
                id: $0,
                title: workspaceToolTitle(for: $0),
                systemImage: workspaceToolSystemImage(for: $0),
                requiresWorkspace: true
            )
        }
        return builtInToolOptions
            + (hasWorkspace ? workspaceOptions : [])
            + (hasTerminal ? terminalToolOptions : [])
    }

    public static func effectiveEnabledToolIDs(_ storedIDs: [String], hasWorkspace: Bool, hasTerminal: Bool = false) -> Set<String> {
        let available = Set(toolOptions(hasWorkspace: hasWorkspace, hasTerminal: hasTerminal).map(\.id))
        guard !storedIDs.isEmpty else { return available }
        return Set(storedIDs).intersection(available)
    }

    public static func persistedEnabledToolIDs(_ selectedIDs: Set<String>, hasWorkspace: Bool, hasTerminal: Bool = false) -> [String] {
        let available = Set(toolOptions(hasWorkspace: hasWorkspace, hasTerminal: hasTerminal).map(\.id))
        let normalized = selectedIDs.intersection(available)
        if normalized == available {
            return []
        }
        return normalized.sorted()
    }

    private static func workspaceToolTitle(for id: String) -> String {
        switch id {
        case "cat": "Read File"
        case "ls": "List Directory"
        case "find": "Find File"
        case "search_files": "Search Files"
        case "grep": "Search File Content"
        case "change_directory": "Change Directory"
        default: id
        }
    }

    private static func workspaceToolSystemImage(for id: String) -> String {
        switch id {
        case "cat": "doc.text"
        case "ls": "list.bullet"
        case "find": "magnifyingglass"
        case "search_files": "text.magnifyingglass"
        case "grep": "doc.text.magnifyingglass"
        case "change_directory": "folder.badge.gearshape"
        default: "wrench.and.screwdriver"
        }
    }
}

public enum WorkspaceAttachmentSupport {
    public static var defaultDocumentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Attaches a new workspace folder to the conversation, adding its id to `attachedWorkspaceIds`
    /// and enabling its folder-backed tools. Safe to call repeatedly with different URLs;
    /// each call appends a new workspace id.
    ///
    /// For backward compatibility during transition from single-attach to multi-attach, also sets
    /// `workspaceId` to the first/only attached workspace id (this field is deprecated).
    @discardableResult
    public static func attachWorkspace(to conversation: ConversationModel, modelContext: ModelContext, url: URL) -> WorkspaceModel {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        let workspace = WorkspaceModel(displayName: url.lastPathComponent, folderPath: url.path, bookmarkData: bookmark)
        modelContext.insert(workspace)

        // Add to the multi-attach array
        if !conversation.attachedWorkspaceIds.contains(workspace.id) {
            conversation.attachedWorkspaceIds.append(workspace.id)
        }

        // Also set the legacy single-attach field for backward compat (only if not already set)
        if conversation.workspaceId == nil {
            conversation.workspaceId = workspace.id
        }

        // Enable folder tools (at least one workspace now exists)
        let selectedTools = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: false)
            .union(FileSystemWorkspace.toolIds)
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selectedTools, hasWorkspace: true)

        try? modelContext.save()
        return workspace
    }

    /// Detaches a specific workspace by id from the conversation, removing it from `attachedWorkspaceIds`.
    /// Also removes its folder tools from `enabledToolIds` if no other workspace remains attached.
    /// Also nils `workspaceId` if the detached id matches it (legacy single-attach cleanup).
    /// Safe to call multiple times; if the id is not attached, this is a no-op.
    @discardableResult
    public static func detachWorkspace(id: UUID, from conversation: ConversationModel, modelContext: ModelContext) -> [UUID] {
        conversation.attachedWorkspaceIds.removeAll { $0 == id }

        // Also clean up legacy single-attach field if it matches
        if conversation.workspaceId == id {
            conversation.workspaceId = nil
        }

        // Resolve the workspaces still attached after removal, so reconcileEnabledTools can
        // recompute enabledToolIds from the actual remaining attachments rather than just a count.
        // Drive resolution off `allAttachedWorkspaceIds` (folds in the legacy `workspaceId`) so
        // this short-circuit agrees with WorkspaceResolutionHelper's source of truth: a
        // non-matching legacy id left on `workspaceId` still counts as an attachment even when
        // `attachedWorkspaceIds` is empty.
        let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<WorkspaceModel>())) ?? []
        let remainingWorkspaces = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)

        reconcileEnabledTools(for: conversation, attachedWorkspaces: remainingWorkspaces)

        return pruneOrphanWorkspaces(modelContext: modelContext)
    }

    /// Recomputes `conversation.enabledToolIds` so it never references tools whose backing
    /// workspace is no longer attached — the central invariant for tool-id consistency.
    ///
    /// Recomputes `conversation.enabledToolIds` from the *kinds* of the currently-attached
    /// workspaces: folder tools (`FileSystemWorkspace.toolIds`) stay enabled iff a folder
    /// workspace remains attached, and terminal tools iff a terminal workspace remains. Routing
    /// through `effectiveEnabledToolIDs`/`persistedEnabledToolIDs` (whose `available` set excludes
    /// the now-ungated kinds) drops any tool ids whose backing workspace kind is gone, so
    /// `enabledToolIds` never references a tool with no attached workspace of its kind.
    public static func reconcileEnabledTools(for conversation: ConversationModel, attachedWorkspaces: [WorkspaceModel]) {
        let hasFolder = attachedWorkspaces.contains { $0.kind == .folder }
        let hasTerminal = attachedWorkspaces.contains { $0.kind == .terminal }

        let reconciled = ConversationToolSupport.effectiveEnabledToolIDs(
            conversation.enabledToolIds,
            hasWorkspace: hasFolder,
            hasTerminal: hasTerminal
        )
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(
            reconciled,
            hasWorkspace: hasFolder,
            hasTerminal: hasTerminal
        )
    }

    /// Detaches the first (or legacy single) attached workspace from the conversation.
    /// This is a backward-compatibility overload for existing UI code that detaches without specifying an id.
    /// (Task 4 will update UI to work with multi-attach, at which point this can be removed.)
    @discardableResult
    public static func detachWorkspace(from conversation: ConversationModel, modelContext: ModelContext) -> [UUID] {
        // Prefer the legacy single-attach field if set (for backward compat with existing data)
        if let legacyId = conversation.workspaceId {
            return detachWorkspace(id: legacyId, from: conversation, modelContext: modelContext)
        } else if let firstId = conversation.attachedWorkspaceIds.first {
            // Otherwise detach the first workspace in the array
            return detachWorkspace(id: firstId, from: conversation, modelContext: modelContext)
        }
        return []
    }

    /// Idempotent backfill: moves a non-nil `workspaceId` into `attachedWorkspaceIds` and nils
    /// the legacy field. Safe to call every time a conversation loads; repeated calls are no-ops.
    ///
    /// If `workspaceId` is nil, this is a no-op. If the legacy id is already present in
    /// `attachedWorkspaceIds`, it is not duplicated.
    public static func backfillLegacyAttachment(_ conversation: ConversationModel) {
        guard let legacyId = conversation.workspaceId else { return }
        if !conversation.attachedWorkspaceIds.contains(legacyId) {
            conversation.attachedWorkspaceIds.append(legacyId)
        }
        conversation.workspaceId = nil
    }

    /// Deletes any `WorkspaceModel` rows that are not referenced by any conversation's
    /// `allAttachedWorkspaceIds` (which folds in the legacy `workspaceId` field). Safe to call
    /// repeatedly — workspaces still referenced by at least one conversation are left untouched,
    /// and calling this with no orphans present is a no-op.
    ///
    /// Returns the ids of any pruned **terminal** workspaces so the caller can tear down their
    /// live `TerminalSession`s in the runtime's registry (this layer is pure-SwiftData and has
    /// no access to the registry).
    @discardableResult
    public static func pruneOrphanWorkspaces(modelContext: ModelContext) -> [UUID] {
        let conversations = (try? modelContext.fetch(FetchDescriptor<ConversationModel>())) ?? []
        let referencedIds = Set(conversations.flatMap(\.allAttachedWorkspaceIds))

        let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<WorkspaceModel>())) ?? []
        var prunedTerminalIds: [UUID] = []
        for workspace in allWorkspaces where !referencedIds.contains(workspace.id) {
            if workspace.kind == .terminal { prunedTerminalIds.append(workspace.id) }
            modelContext.delete(workspace)
        }

        try? modelContext.save()
        return prunedTerminalIds
    }

    /// Deletes `conversation` and cleans up any workspaces it was the sole referrer of. Returns
    /// the ids of pruned terminal workspaces so the caller can terminate their live sessions.
    @discardableResult
    public static func deleteConversation(_ conversation: ConversationModel, modelContext: ModelContext) -> [UUID] {
        modelContext.delete(conversation)
        try? modelContext.save()
        return pruneOrphanWorkspaces(modelContext: modelContext)
    }

    /// Creates and attaches a terminal workspace to `conversation`, rooted at `folder`'s path
    /// (YAK-T5). Inserts a `WorkspaceModel(kind: .terminal)` whose `folderPath` is the shell's
    /// initial working directory, appends its id to `attachedWorkspaceIds`, and enables the five
    /// terminal tool ids while preserving the conversation's existing (folder/built-in) tools.
    @discardableResult
    public static func attachTerminal(
        to conversation: ConversationModel,
        fromFolder folder: WorkspaceModel,
        modelContext: ModelContext
    ) -> WorkspaceModel {
        let terminal = WorkspaceModel(
            displayName: "Terminal — \(folder.displayName)",
            folderPath: folder.folderPath,
            bookmarkData: nil,
            kind: .terminal
        )
        modelContext.insert(terminal)
        conversation.attachedWorkspaceIds.append(terminal.id)

        // Whether a folder workspace remains attached governs whether folder tools stay offered.
        let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<WorkspaceModel>())) ?? []
        let attached = WorkspaceResolutionHelper.attachedWorkspaces(for: conversation, in: allWorkspaces)
        let hasFolder = attached.contains { $0.kind == .folder }

        let selected = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: hasFolder, hasTerminal: false)
            .union(TerminalWorkspace.toolIds)
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selected, hasWorkspace: hasFolder, hasTerminal: true)

        try? modelContext.save()
        return terminal
    }
}

/// Pure resolution helpers for turning a conversation's attached-id list into concrete
/// `WorkspaceModel`s, given the full set of workspaces fetched by the view (e.g. via `@Query`).
public enum WorkspaceResolutionHelper {
    /// Returns the `WorkspaceModel`s referenced by `conversation.allAttachedWorkspaceIds`, in
    /// that order, filtering out any ids that have no matching workspace in `workspaces`.
    public static func attachedWorkspaces(for conversation: ConversationModel, in workspaces: [WorkspaceModel]) -> [WorkspaceModel] {
        let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        return conversation.allAttachedWorkspaceIds.compactMap { byId[$0] }
    }
}
