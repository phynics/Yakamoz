import Foundation
import SwiftData

public struct ConversationToolOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let requiresWorkspace: Bool

    public init(id: String, title: String, systemImage: String, requiresWorkspace: Bool) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.requiresWorkspace = requiresWorkspace
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

    public static func toolOptions(hasWorkspace: Bool) -> [ConversationToolOption] {
        let workspaceOptions = FileSystemWorkspace.toolIds.map {
            ConversationToolOption(
                id: $0,
                title: workspaceToolTitle(for: $0),
                systemImage: workspaceToolSystemImage(for: $0),
                requiresWorkspace: true
            )
        }
        return builtInToolOptions + (hasWorkspace ? workspaceOptions : [])
    }

    public static func effectiveEnabledToolIDs(_ storedIDs: [String], hasWorkspace: Bool) -> Set<String> {
        let available = Set(toolOptions(hasWorkspace: hasWorkspace).map(\.id))
        guard !storedIDs.isEmpty else { return available }
        return Set(storedIDs).intersection(available)
    }

    public static func persistedEnabledToolIDs(_ selectedIDs: Set<String>, hasWorkspace: Bool) -> [String] {
        let available = Set(toolOptions(hasWorkspace: hasWorkspace).map(\.id))
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
    public static func detachWorkspace(id: UUID, from conversation: ConversationModel, modelContext: ModelContext) {
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

        try? modelContext.save()
    }

    /// Recomputes `conversation.enabledToolIds` so it never references tools whose backing
    /// workspace is no longer attached — the central invariant for tool-id consistency.
    ///
    /// Forward-compat note: `WorkspaceModel` does not yet have a `kind` field (folder vs.
    /// terminal workspaces are not yet distinguished). This function is kind-agnostic for now —
    /// every attached workspace is treated as a folder workspace, so folder tools
    /// (`FileSystemWorkspace.toolIds`) are allowed iff `attachedWorkspaces` is non-empty. Once
    /// `WorkspaceModel.kind` exists, this can be extended to per-kind reconciliation (folder tools
    /// iff any folder workspace remains; terminal tools iff any terminal workspace remains)
    /// without changing this signature, since it already takes the resolved `[WorkspaceModel]`s.
    public static func reconcileEnabledTools(for conversation: ConversationModel, attachedWorkspaces: [WorkspaceModel]) {
        let hasFolder = !attachedWorkspaces.isEmpty

        if hasFolder {
            conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(
                ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: true),
                hasWorkspace: true
            )
        } else {
            let selectedTools = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: true)
                .subtracting(FileSystemWorkspace.toolIds)
            conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selectedTools, hasWorkspace: false)
        }
    }

    /// Detaches the first (or legacy single) attached workspace from the conversation.
    /// This is a backward-compatibility overload for existing UI code that detaches without specifying an id.
    /// (Task 4 will update UI to work with multi-attach, at which point this can be removed.)
    public static func detachWorkspace(from conversation: ConversationModel, modelContext: ModelContext) {
        // Prefer the legacy single-attach field if set (for backward compat with existing data)
        if let legacyId = conversation.workspaceId {
            detachWorkspace(id: legacyId, from: conversation, modelContext: modelContext)
        } else if let firstId = conversation.attachedWorkspaceIds.first {
            // Otherwise detach the first workspace in the array
            detachWorkspace(id: firstId, from: conversation, modelContext: modelContext)
        }
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
    public static func pruneOrphanWorkspaces(modelContext: ModelContext) {
        let conversations = (try? modelContext.fetch(FetchDescriptor<ConversationModel>())) ?? []
        let referencedIds = Set(conversations.flatMap(\.allAttachedWorkspaceIds))

        let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<WorkspaceModel>())) ?? []
        for workspace in allWorkspaces where !referencedIds.contains(workspace.id) {
            modelContext.delete(workspace)
        }

        try? modelContext.save()
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
