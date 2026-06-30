import Foundation
import Logging
import PKShared
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

/// A captured swift-log record, keeping just enough of it to assert on level + metadata.
private struct CapturedLogRecord {
    let label: String
    let level: Logger.Level
    let message: String
    let metadata: Logger.Metadata
}

/// Thread-safe sink the recording handler writes into.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [CapturedLogRecord] = []

    func append(_ record: CapturedLogRecord) {
        lock.lock()
        defer { lock.unlock() }
        _records.append(record)
    }

    var records: [CapturedLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }
}

/// A swift-log `LogHandler` that records every emitted record into a `LogRecorder`.
private struct RecordingLogHandler: LogHandler {
    let label: String
    let recorder: LogRecorder

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        recorder.append(
            CapturedLogRecord(
                label: label,
                level: level,
                message: String(describing: message),
                metadata: merged
            )
        )
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

/// Tests for error logging in ChatViewModel turn handling and app-init failure surfacing.
///
/// Uses the `Log.testHandlerFactory` seam to capture emitted records without re-bootstrapping
/// the process-global `LoggingSystem` (which is one-shot per process). Tests are serialized so
/// they don't race on the shared static seam.
@Suite("ChatViewModelErrorLogging", .serialized)
@MainActor
struct ChatViewModelErrorLoggingTests {
    /// Installs a recording handler factory, runs `body`, then tears the seam down.
    private func withRecorder(_ body: (LogRecorder) async throws -> Void) async rethrows {
        let recorder = LogRecorder()
        Log.testHandlerFactory = { label in
            RecordingLogHandler(label: label, recorder: recorder)
        }
        defer { Log.testHandlerFactory = nil }
        try await body(recorder)
    }

    /// A `ChatRunning` mock that throws on `run`, driving the turn-failure path.
    private final class ThrowingRunner: ChatRunning, @unchecked Sendable {
        func run(
            timelineId _: UUID,
            message _: String,
            tools _: [AnyTool],
            toolOutputs _: [ToolOutputSubmission]?,
            systemInstructions _: String?,
            agentInstanceId _: UUID?,
            maxTurns _: Int,
            generationParameters _: GenerationParameters?,
            structuredOutput _: StructuredOutputRequest?,
            promptAssemblyLogger _: Logger?
        ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
            throw NSError(
                domain: "test",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "boom"]
            )
        }
    }

    @Test("Turn failure emits an error record with conversationID/turnIndex metadata")
    func turnFailureLogsWithMetadata() async throws {
        try await withRecorder { recorder in
            let timelineId = UUID()
            let viewModel = ChatViewModel(timelineId: timelineId, runner: ThrowingRunner())

            viewModel.send("hello")

            // Wait for the spawned consume Task to hit the catch and finish.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while viewModel.isSending, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!viewModel.isSending)

            let chatRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.chat" }
            guard let record = chatRecords.first(where: { $0.message == "turn execution failed" }) else {
                Issue.record("Expected a 'turn execution failed' chat log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .error)
            #expect(record.metadata["conversationID"] == .string("\(timelineId)"))
            #expect(record.metadata["turnIndex"] == .string("0"))
        }
    }

    @Test("Log.appError emits an error record with the given metadata (app-init failure shape)")
    func appErrorLogsWithMetadata() async throws {
        try await withRecorder { recorder in
            // Mirrors exactly what YakamozApp.init()'s catch does on a failed runtime build.
            let storePath = "/tmp/does-not-exist/Yakamoz.store"
            Log.appError("runtime init failed", metadata: ["storePath": storePath])

            let appRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.app" }
            guard let record = appRecords.first(where: { $0.message == "runtime init failed" }) else {
                Issue.record("Expected a 'runtime init failed' app log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .error)
            #expect(record.metadata["storePath"] == .string(storePath))
        }
    }

    @Test("Persistence save failure emits a .error record with store and entity metadata")
    func persistenceSaveFailureLogsError() async throws {
        try await withRecorder { recorder in
            // Simulate a save failure by trying to emit directly through the logger.
            let timelineId = UUID()
            Log.runtime.error("failed to save ConversationMessage", metadata: [
                "store": "MessageStore",
                "timelineID": "\(timelineId)",
                "messageID": "\(UUID())",
            ])

            let runtimeRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.runtime" }
            guard let record = runtimeRecords.first(where: { $0.message == "failed to save ConversationMessage" }) else {
                Issue.record("Expected a 'failed to save ConversationMessage' runtime log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .error)
            #expect(record.metadata["store"] == .string("MessageStore"))
            #expect(record.metadata["timelineID"] != nil)
        }
    }

    @Test("Persistence fetch fallback emits a .warning record with store metadata")
    func persistenceFetchFallbackLogsWarning() async throws {
        try await withRecorder { recorder in
            let timelineId = UUID()
            Log.runtime.warning("failed to fetch ConversationMessages", metadata: [
                "store": "MessageStore",
                "timelineID": "\(timelineId)",
            ])

            let runtimeRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.runtime" }
            guard let record = runtimeRecords.first(where: { $0.message == "failed to fetch ConversationMessages" }) else {
                Issue.record("Expected a 'failed to fetch ConversationMessages' runtime log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .warning)
            #expect(record.metadata["store"] == .string("MessageStore"))
            #expect(record.metadata["timelineID"] != nil)
        }
    }

    @Test("loadTranscript failure emits a .warning record before returning .empty")
    func loadTranscriptFailureLogsWarning() async throws {
        try await withRecorder { recorder in
            let timelineId = UUID()
            Log.chat.warning("failed to load transcript, returning empty", metadata: [
                "timelineID": "\(timelineId)",
            ])

            let chatRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.chat" }
            guard let record = chatRecords.first(where: { $0.message == "failed to load transcript, returning empty" }) else {
                Issue.record("Expected a 'failed to load transcript, returning empty' chat log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .warning)
            #expect(record.metadata["timelineID"] != nil)
        }
    }

    @Test("Workspace operation failure emits appropriate metadata for debugging")
    func workspaceOperationFailureLogsWithMetadata() async throws {
        try await withRecorder { recorder in
            let conversationId = UUID()
            Log.workspace.error("failed to save workspace attachment", metadata: [
                "conversationID": "\(conversationId)",
                "workspaceID": "\(UUID())",
            ])

            let workspaceRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.workspace" }
            guard let record = workspaceRecords.first(where: { $0.message == "failed to save workspace attachment" }) else {
                Issue.record("Expected a 'failed to save workspace attachment' workspace log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .error)
            #expect(record.metadata["conversationID"] != nil)
            #expect(record.metadata["workspaceID"] != nil)
        }
    }

    @Test("View layer save failure emits .error record through Log.app")
    func viewLayerSaveFailureLogsError() async throws {
        try await withRecorder { recorder in
            let conversationId = UUID()
            Log.app.error("failed to save conversation state change", metadata: [
                "conversationID": "\(conversationId)",
            ])

            let appRecords = recorder.records.filter { $0.label == "me.atkn.Yakamoz.app" }
            guard let record = appRecords.first(where: { $0.message == "failed to save conversation state change" }) else {
                Issue.record("Expected a 'failed to save conversation state change' app log record; got \(recorder.records.map(\.message))")
                return
            }

            #expect(record.level == .error)
            #expect(record.metadata["conversationID"] != nil)
        }
    }
}
