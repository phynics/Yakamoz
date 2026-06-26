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

    @discardableResult
    public static func attachWorkspace(to conversation: ConversationModel, modelContext: ModelContext, url: URL) -> WorkspaceModel {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        let workspace = WorkspaceModel(displayName: url.lastPathComponent, folderPath: url.path, bookmarkData: bookmark)
        modelContext.insert(workspace)
        conversation.workspaceId = workspace.id

        let selectedTools = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: false)
            .union(FileSystemWorkspace.toolIds)
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selectedTools, hasWorkspace: true)

        try? modelContext.save()
        return workspace
    }

    public static func detachWorkspace(from conversation: ConversationModel, modelContext: ModelContext) {
        let selectedTools = ConversationToolSupport.effectiveEnabledToolIDs(conversation.enabledToolIds, hasWorkspace: true)
            .subtracting(FileSystemWorkspace.toolIds)
        conversation.workspaceId = nil
        conversation.enabledToolIds = ConversationToolSupport.persistedEnabledToolIDs(selectedTools, hasWorkspace: false)
        try? modelContext.save()
    }

    /// One-time backfill: moves a non-nil `workspaceId` into `attachedWorkspaceIds` and nils
    /// the legacy field. Idempotent — safe to call every time a conversation loads.
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
}
