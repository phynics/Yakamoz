import Foundation
import PKShared
import PositronicKit

/// The lifecycle state of a single tool invocation within a turn, mirrored from
/// `ToolExecutionStatus` plus a terminal `succeeded`/`failed` split so the UI can
/// render a stable badge without re-deriving it from the raw status each time.
public enum ToolTraceState: Sendable, Equatable {
    case attempting
    case succeeded
    case failed
}

/// A `Sendable` projection of one tool call's lifecycle within a turn: name/args at
/// the time it started, output/error once it finishes, and timing derived from the
/// injected `ContinuousClock` instants the reducer was driven with.
public struct ToolTrace: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var state: ToolTraceState
    public var output: String?
    public var error: String?
    public var startedAt: ContinuousClock.Instant?
    public var finishedAt: ContinuousClock.Instant?

    public init(
        id: String,
        name: String,
        state: ToolTraceState = .attempting,
        output: String? = nil,
        error: String? = nil,
        startedAt: ContinuousClock.Instant? = nil,
        finishedAt: ContinuousClock.Instant? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.output = output
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Elapsed time between `startedAt` and `finishedAt`, when both are known.
    public var elapsed: Duration? {
        guard let startedAt, let finishedAt else { return nil }
        return startedAt.duration(to: finishedAt)
    }
}

/// The accumulated, reducer-owned state of a single in-flight (or completed) assistant
/// turn: reconstructed streaming text/thinking, per-tool traces (ordered by first
/// appearance), workspace context files, and final response metadata.
///
/// This is the pure-data target of `ChatEventReducer.reduce` — it carries no behavior
/// beyond small mutating helpers so the reducer itself stays a single dispatch point.
public struct ChatTurnState: Sendable, Equatable {
    public struct Response: Sendable, Equatable {
        public var reconstructedText: String = ""
        public var thinking: String = ""
        public var model: String?
        public var finishReason: String?
        public var inputTokens: Int?
        public var outputTokens: Int?
    }

    public let turnIndex: Int
    public var response = Response()
    public var workspaceFiles: [String] = []
    /// Tool traces in first-seen order, keyed by `toolCallId`.
    public var toolOrder: [String] = []
    public var tools: [String: ToolTrace] = [:]
    public var isComplete = false
    public var isCancelled = false
    public var errorMessage: String?

    public init(turnIndex: Int) {
        self.turnIndex = turnIndex
    }

    /// Tool traces in the order they were first observed.
    public var orderedTools: [ToolTrace] {
        toolOrder.compactMap { tools[$0] }
    }

    /// Applies a tool execution status update, creating the trace on first sight and
    /// recording start/finish instants so `ToolTrace.elapsed` can be derived later.
    ///
    /// A completed turn (`isComplete == true`) never mutates: once a turn has reached
    /// its terminal state, later events (e.g. a stray late delta from a superseded
    /// stream) are ignored rather than corrupting already-finalized history.
    public mutating func applyToolStatus(
        id: String,
        status: ToolExecutionStatus,
        now: ContinuousClock.Instant
    ) {
        guard !isComplete else { return }

        if !tools.keys.contains(id) {
            toolOrder.append(id)
        }

        var trace = tools[id] ?? ToolTrace(id: id, name: id)

        switch status {
        case let .attempting(name, _):
            trace.name = name
            trace.state = .attempting
            if trace.startedAt == nil {
                trace.startedAt = now
            }
        case let .success(result):
            trace.state = .succeeded
            trace.output = result.output
            trace.error = result.error
            trace.finishedAt = now
        case let .failed(reference, error):
            trace.state = .failed
            trace.name = reference.displayName
            trace.error = error
            trace.finishedAt = now
        case let .failure(error):
            trace.state = .failed
            trace.error = error
            trace.finishedAt = now
        }

        tools[id] = trace
    }

    /// Records final model/finish-reason/token-usage metadata from a `generationCompleted` event.
    /// A completed turn never mutates further.
    public mutating func apply(_ metadata: APIResponseMetadata) {
        guard !isComplete else { return }
        response.model = metadata.model
        response.finishReason = metadata.finishReason
        response.inputTokens = metadata.promptTokens
        response.outputTokens = metadata.completionTokens
    }

    /// Converts the accumulated state into the `ResponseDTO` shape persisted by the
    /// turn inspector (Task 3's `SwiftDataTurnInspector.updateResponse`).
    public var responseDTO: ResponseDTO {
        ResponseDTO(
            reconstructedText: response.reconstructedText,
            thinking: response.thinking,
            model: response.model,
            finishReason: response.finishReason,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens
        )
    }
}

/// A single entry in the chat transcript shown to the user: either a persisted
/// human/system message, or the live/finished view of an assistant turn.
public struct ChatPromptOption: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct ChatPrompt: Sendable, Equatable {
    public let title: String
    public let detail: String?
    public let options: [ChatPromptOption]

    public init(title: String, detail: String? = nil, options: [ChatPromptOption]) {
        self.title = title
        self.detail = detail
        self.options = options
    }
}

public enum TranscriptItem: Sendable, Identifiable, Equatable {
    case user(id: UUID, text: String, timestamp: Date)
    case assistant(id: UUID, turn: ChatTurnState)
    case error(id: UUID, message: String)
    case prompt(id: UUID, prompt: ChatPrompt)

    public var id: UUID {
        switch self {
        case let .user(id, _, _): id
        case let .assistant(id, _): id
        case let .error(id, _): id
        case let .prompt(id, _): id
        }
    }
}

/// A pure, deterministic reducer that folds a single `ChatEvent` into a `ChatTurnState`.
///
/// Driven by an injected `ContinuousClock.Instant` (`now`) rather than reading the
/// clock itself, so reducer tests are fully deterministic and never sleep. Once
/// `state.isComplete` is set (by `.streamCompleted`), later events are ignored: a new
/// turn must never mutate a turn that has already finished.
public enum ChatEventReducer {
    public static func reduce(_ event: ChatEvent, into state: inout ChatTurnState, now: ContinuousClock.Instant) {
        guard !state.isComplete else { return }

        if let text = event.textContent {
            state.response.reconstructedText += text
        }
        if let thought = event.thinkingContent {
            state.response.thinking += thought
        }

        switch event {
        case let .delta(event: .toolExecution(toolCallId: id, status: status)),
             let .completion(event: .toolExecution(toolCallId: id, status: status)):
            state.applyToolStatus(id: id, status: status, now: now)

        case let .meta(event: .generationContext(metadata: metadata)):
            state.workspaceFiles = metadata.files

        case let .delta(event: .toolCall):
            break

        case let .meta(event: .generationCompleted(message: _, metadata: metadata)):
            state.apply(metadata)

        case let .completion(event: .generationCompleted(message: _, metadata: metadata)):
            state.apply(metadata)

        case let .error(event: .toolCallError(toolCallId: id, name: name, error: error)):
            var trace = state.tools[id] ?? ToolTrace(id: id, name: name)
            if !state.tools.keys.contains(id) {
                state.toolOrder.append(id)
            }
            trace.name = name
            trace.state = .failed
            trace.error = error
            trace.finishedAt = now
            state.tools[id] = trace

        case .error(event: .generationCancelled):
            state.isCancelled = true

        case let .error(event: .error(message: message)):
            state.errorMessage = message

        case .completion(event: .streamCompleted):
            state.isComplete = true

        case .delta(event: .thinking), .delta(event: .generation):
            break
        }
    }
}
