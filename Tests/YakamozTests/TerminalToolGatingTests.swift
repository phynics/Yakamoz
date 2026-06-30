import Foundation
import PKShared
import PKTestSupport
import PositronicKit
import SQLite3
import SwiftData
import Testing
@testable import YakamozCore

struct TerminalToolGatingTests {
    // MARK: - WorkspaceModel.kind

    @Test func workspaceModelDefaultsToFolderKind() {
        let ws = WorkspaceModel(displayName: "w", folderPath: "/tmp")
        #expect(ws.kind == .folder)
    }

    @Test func workspaceModelCanBeTerminalKind() {
        let ws = WorkspaceModel(displayName: "term", folderPath: "/tmp", kind: .terminal)
        #expect(ws.kind == .terminal)
    }

    @Test func workspaceModelDefaultsToFolderWhenPersistedKindIsMissing() throws {
        let storeURL = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let workspaceID = UUID()
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: storeURL)
            let context = ModelContext(container)
            context.insert(WorkspaceModel(id: workspaceID, displayName: "legacy", folderPath: "/tmp/legacy"))
            try context.save()
        }

        try clearPersistedWorkspaceKind(in: storeURL)

        let container = try makeModelContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let workspace = try #require(try context.fetch(FetchDescriptor<WorkspaceModel>()).first { $0.id == workspaceID })

        #expect(workspace.kind == .folder)
    }

    // MARK: - toolOptions gating

    @Test func terminalOptionsAppearOnlyWhenHasTerminal() {
        let withoutTerminal = ConversationToolSupport.toolOptions(hasWorkspace: false, hasTerminal: false)
        #expect(withoutTerminal.allSatisfy { !$0.requiresTerminal })

        let withTerminal = ConversationToolSupport.toolOptions(hasWorkspace: false, hasTerminal: true)
        let terminalIds = Set(withTerminal.filter { $0.requiresTerminal }.map(\.id))
        #expect(terminalIds == ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"])
    }

    @Test func toolOptionsDefaultsHasTerminalFalse() {
        // The default-parameter form (used by folder-only call sites) excludes terminal options.
        let options = ConversationToolSupport.toolOptions(hasWorkspace: true)
        #expect(options.allSatisfy { !$0.requiresTerminal })
    }

    // MARK: - resolveTools terminal wiring

    @MainActor
    private func makeRuntime() throws -> YakamozRuntime {
        let container = try makeModelContainer()
        let suiteName = "TerminalToolGatingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = ProviderSettings(defaults: defaults)
        settings.applyPreset(.openAI)
        settings.model = "gpt-4o-test"
        let mock = MockLLMService()
        return try YakamozRuntime(
            modelContainer: container,
            settings: settings,
            secrets: FakeSecretStore(),
            llmServiceFactory: { _ in mock }
        )
    }

    @MainActor
    @Test func resolveToolsAppendsTerminalToolsOnlyForAttachedTerminals() throws {
        let runtime = try makeRuntime()

        // No terminals → no terminal tools.
        let none = runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil, terminals: [])
        #expect(!none.map(\.id).contains("terminal_run"))

        // One terminal context → its five tools appear.
        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let withTerminal = runtime.resolveTools(enabledToolIds: [], workspaceRoot: nil, terminals: [ctx])
        let ids = Set(withTerminal.map(\.id))
        #expect(ids.isSuperset(of: ["terminal_run", "terminal_read", "terminal_send_input", "terminal_interrupt", "terminal_wait"]))
    }

    @MainActor
    @Test func resolveToolsRespectsEnabledFilterForTerminalTools() throws {
        let runtime = try makeRuntime()
        let ctx = TerminalToolContext(workspaceId: UUID(), rootURL: URL(fileURLWithPath: "/tmp"))
        let filtered = runtime.resolveTools(
            enabledToolIds: ["terminal_run"],
            workspaceRoot: nil,
            terminals: [ctx]
        )
        let ids = filtered.map(\.id)
        #expect(ids == ["terminal_run"])
    }
}

private func makeModelContainer(storeURL: URL? = nil) throws -> ModelContainer {
    let schema = Schema(YakamozSchema.models)
    let configuration: ModelConfiguration
    if let storeURL {
        configuration = ModelConfiguration(schema: schema, url: storeURL)
    } else {
        configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    }
    return try ModelContainer(for: schema, configurations: configuration)
}

private func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("YakamozTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("Yakamoz.store", isDirectory: false)
}

private enum SQLiteFixtureError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case execute(String)
    case missingWorkspaceKindColumn

    var description: String {
        switch self {
        case let .open(message): "Unable to open SQLite fixture: \(message)"
        case let .prepare(message): "Unable to prepare SQLite fixture statement: \(message)"
        case let .execute(message): "Unable to execute SQLite fixture statement: \(message)"
        case .missingWorkspaceKindColumn: "Unable to find a persisted workspace kind column"
        }
    }
}

private func clearPersistedWorkspaceKind(in storeURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        throw SQLiteFixtureError.open(sqliteMessage(database))
    }
    defer { sqlite3_close(database) }

    let tables = try sqliteTextRows(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    let workspaceTables = tables.filter { $0.uppercased().contains("WORKSPACEMODEL") }
    var clearedKindColumn = false

    for table in workspaceTables {
        let columns = try sqliteTextRows(database, sql: "PRAGMA table_info(\(quotedSQLiteIdentifier(table)))", textColumn: 1)
        for column in columns where column.uppercased().contains("KIND") {
            let sql = "UPDATE \(quotedSQLiteIdentifier(table)) SET \(quotedSQLiteIdentifier(column)) = NULL"
            try sqliteExecute(database, sql: sql)
            clearedKindColumn = true
        }
    }

    guard clearedKindColumn else {
        throw SQLiteFixtureError.missingWorkspaceKindColumn
    }
}

private func sqliteTextRows(_ database: OpaquePointer?, sql: String, textColumn: Int32 = 0) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteFixtureError.prepare(sqliteMessage(database))
    }
    defer { sqlite3_finalize(statement) }

    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let text = sqlite3_column_text(statement, textColumn) else { continue }
        rows.append(String(cString: text))
    }
    return rows
}

private func sqliteExecute(_ database: OpaquePointer?, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    defer { sqlite3_free(errorMessage) }

    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage(database)
        throw SQLiteFixtureError.execute(message)
    }
}

private func sqliteMessage(_ database: OpaquePointer?) -> String {
    guard let database else { return "unknown SQLite error" }
    return String(cString: sqlite3_errmsg(database))
}

private func quotedSQLiteIdentifier(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}
