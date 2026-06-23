import Foundation
import Logging
import PKShared
import PositronicKit

/// The seam between `ChatViewModel` and `PositronicKit.run`.
///
/// Mirrors the facade's `run(...)` signature exactly so `PositronicKit` itself can
/// conform via a trivial extension below, while tests substitute a scripted fake that
/// yields a hand-built `AsyncThrowingStream<ChatEvent, Error>` — no network, no real
/// `ChatEngine`, no sleeps.
public protocol ChatRunning: Sendable {
    func run(
        timelineId: UUID,
        message: String,
        tools: [AnyTool],
        toolOutputs: [ToolOutputSubmission]?,
        systemInstructions: String?,
        agentInstanceId: UUID?,
        maxTurns: Int,
        generationParameters: GenerationParameters?,
        structuredOutput: StructuredOutputRequest?,
        promptAssemblyLogger: Logger?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error>
}

extension PositronicKit: ChatRunning {}

/// Main-actor, `@Observable` view model that drives a single chat conversation:
/// sends user text through a `ChatRunning` runner, live-reduces the resulting
/// `ChatEvent` stream into the transcript via `ChatEventReducer`, and persists the
/// final turn's response metadata via the turn inspector.
///
/// `PositronicKit.run` (through `ChatEngine`) already persists the user and assistant
/// `ConversationMessage` rows itself (see `ChatEngine+ContextBuilding.saveConversationSteps`
/// and `MessagePersistenceStage`); this view model does not duplicate that write. The
/// one persistence gap it fills is `SwiftDataTurnInspector.updateResponse`, which
/// records reconstructed text/thinking/model/finish-reason/token-usage onto the
/// turn-inspection row that `didComposeTurn` created earlier in the same turn.
@MainActor
@Observable
public final class ChatViewModel {
    public private(set) var transcript: [TranscriptItem] = []
    public private(set) var isSending = false
    public var selectedTurnIndex: Int?
    public var errorMessage: String?

    /// The `ChatTurnState` for `selectedTurnIndex`, if that turn is an assistant turn
    /// currently in `transcript`. This is the live, in-memory source the Tools inspector
    /// tab reads from in CP9's v1 (see `ToolsInspectorView`'s doc comment): tool traces
    /// are NOT persisted, so this is `nil`/empty again after the conversation reloads
    /// from disk, even though the turn's prompt/response data persists via
    /// `SwiftDataTurnInspector`.
    public var selectedTurnState: ChatTurnState? {
        guard let selectedTurnIndex else { return nil }
        for item in transcript {
            if case let .assistant(_, turn) = item, turn.turnIndex == selectedTurnIndex {
                return turn
            }
        }
        return nil
    }

    private var sendTask: Task<Void, Never>?
    private let runner: any ChatRunning
    private let inspector: SwiftDataTurnInspector?
    private let timelineId: UUID
    private let agentInstanceId: UUID?
    private let tools: [AnyTool]
    private let systemInstructions: String?
    private let maxTurns: Int
    private let generationParameters: GenerationParameters?
    private let structuredOutput: StructuredOutputRequest?
    private let typedReplyEnabled: Bool
    /// Called on the main actor immediately before each user send, before the runner runs.
    /// Used to reset the autonomous-follow-up plugin's per-send guard (see
    /// `AutonomousFollowUpPlugin.beginUserSend()`); `nil` when no plugin is wired.
    private let onBeginUserSend: (@MainActor @Sendable () async -> Void)?
    private let clock: ContinuousClock
    private var nextTurnIndex = 0

    public init(
        timelineId: UUID,
        runner: any ChatRunning,
        inspector: SwiftDataTurnInspector? = nil,
        agentInstanceId: UUID? = nil,
        tools: [AnyTool] = [],
        systemInstructions: String? = nil,
        maxTurns: Int = 5,
        generationParameters: GenerationParameters? = nil,
        structuredOutput: StructuredOutputRequest? = nil,
        typedReplyEnabled: Bool = false,
        onBeginUserSend: (@MainActor @Sendable () async -> Void)? = nil,
        initialTranscript: [TranscriptItem] = [],
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.timelineId = timelineId
        self.runner = runner
        self.inspector = inspector
        self.agentInstanceId = agentInstanceId
        self.tools = tools
        self.systemInstructions = systemInstructions
        self.maxTurns = maxTurns
        self.generationParameters = generationParameters
        self.structuredOutput = structuredOutput
        self.typedReplyEnabled = typedReplyEnabled
        self.onBeginUserSend = onBeginUserSend
        transcript = initialTranscript
        nextTurnIndex = Self.nextTurnIndex(for: initialTranscript)
        self.clock = clock
    }

    /// Sends `text` as the next user message, starting a new turn.
    ///
    /// No-ops if `text` is blank (after trimming) or a turn is already in flight —
    /// callers should disable the send affordance while `isSending` is `true` rather
    /// than relying solely on this guard.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        let userItem = TranscriptItem.user(id: UUID(), text: trimmed, timestamp: Date())
        transcript.append(userItem)

        isSending = true
        errorMessage = nil

        sendTask = Task { [weak self] in
            await self?.onBeginUserSend?()
            await self?.consume(trimmed)
        }
    }

    /// Cancels the in-flight turn, if any. The underlying stream observes task
    /// cancellation; `consume` records `isCancelled` on the in-progress turn state
    /// when the loop is interrupted this way.
    public func cancel() {
        sendTask?.cancel()
    }

    @discardableResult
    public func presentPrompt(_ prompt: ChatPrompt) -> UUID {
        let id = UUID()
        transcript.append(.prompt(id: id, prompt: prompt))
        return id
    }

    public func dismissTranscriptItem(id: UUID) {
        transcript.removeAll { $0.id == id }
    }

    private func consume(_ text: String) async {
        let turnIndex = nextTurnIndex
        nextTurnIndex += 1

        var state = ChatTurnState(turnIndex: turnIndex)
        let assistantItemId = UUID()
        transcript.append(.assistant(id: assistantItemId, turn: state))
        selectedTurnIndex = turnIndex
        var lastRecordedErrorMessage: String?

        defer { isSending = false }

        do {
            let stream = try await runner.run(
                timelineId: timelineId,
                message: text,
                tools: tools,
                toolOutputs: nil,
                systemInstructions: systemInstructions,
                agentInstanceId: agentInstanceId,
                maxTurns: maxTurns,
                generationParameters: generationParameters,
                structuredOutput: structuredOutput,
                promptAssemblyLogger: nil
            )

            eventLoop: for try await event in stream {
                if Task.isCancelled {
                    state.isCancelled = true
                    updateAssistantItem(id: assistantItemId, turn: state)
                    break eventLoop
                }

                ChatEventReducer.reduce(event, into: &state, now: clock.now)
                updateAssistantItem(id: assistantItemId, turn: state)

                if let message = state.errorMessage, message != lastRecordedErrorMessage {
                    lastRecordedErrorMessage = message
                    errorMessage = message
                    state = finalizeFailedTurn(state, assistantItemId: assistantItemId)
                    appendErrorItem(message)
                    break eventLoop
                }
            }

            if Task.isCancelled, !state.isCancelled {
                state.isCancelled = true
                updateAssistantItem(id: assistantItemId, turn: state)
            }

            // The real `ChatEngine` finishes its stream by simply ending the
            // `AsyncThrowingStream` — it never emits a synthetic `.streamCompleted`
            // event (only test runners do). So a turn that streamed to a clean end
            // exits the loop here with `isComplete == false`. Treat a normal,
            // non-cancelled, non-errored loop exit as completion so the response is
            // finalized and persisted exactly as a `.streamCompleted` would have.
            if !state.isCancelled, state.errorMessage == nil, !state.isComplete {
                state.isComplete = true
                updateAssistantItem(id: assistantItemId, turn: state)
            }

            if state.isComplete {
                await persistResponse(turnIndex: turnIndex, state: state)
            }
        } catch is CancellationError {
            state.isCancelled = true
            updateAssistantItem(id: assistantItemId, turn: state)
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            state.errorMessage = message
            state = finalizeFailedTurn(state, assistantItemId: assistantItemId)
            appendErrorItem(message)
        }
    }

    private func finalizeFailedTurn(_ state: ChatTurnState, assistantItemId: UUID) -> ChatTurnState {
        var failedState = state
        guard failedState.hasVisibleTranscriptContent else {
            removeAssistantItem(id: assistantItemId, turnIndex: failedState.turnIndex)
            return failedState
        }

        failedState.isComplete = true
        updateAssistantItem(id: assistantItemId, turn: failedState)
        return failedState
    }

    private func updateAssistantItem(id: UUID, turn: ChatTurnState) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index] = .assistant(id: id, turn: turn)
    }

    private func removeAssistantItem(id: UUID, turnIndex: Int) {
        transcript.removeAll { $0.id == id }
        if selectedTurnIndex == turnIndex {
            selectedTurnIndex = nil
        }
    }

    private func appendErrorItem(_ message: String) {
        transcript.append(.error(id: UUID(), message: message))
    }

    private func persistResponse(turnIndex _: Int, state: ChatTurnState) async {
        guard let inspector else { return }
        do {
            // A single user send can drive several engine LLM round-trips (one per tool
            // loop), each creating its own inspection row; the final assistant text and
            // tool traces belong to the *last* of those rows. Target it via the inspector's
            // latest-turn lookup rather than the view model's single logical turn counter,
            // so a reloaded conversation reads the response off the engine's final turn.
            try await inspector.updateLatestResponse(
                conversationId: timelineId,
                response: enrichedResponseDTO(from: state)
            )
        } catch {
            errorMessage = error.localizedDescription
            appendErrorItem(error.localizedDescription)
        }
    }

    /// For typed-reply conversations, decodes the turn's final text against the
    /// `TypedReplyPayload` schema and folds the schema JSON / parsed JSON / validation error
    /// onto the persisted `ResponseDTO` (see `TypedReply` for why this happens here rather
    /// than through `run()`).
    private func enrichedResponseDTO(from state: ChatTurnState) -> ResponseDTO {
        var dto = state.responseDTO
        // Persist the turn's tool traces so the Tools/Workspace inspector tabs survive a
        // relaunch (they previously lived only in the in-memory `ChatTurnState`).
        dto.tools = state.toolTraceDTOs
        guard typedReplyEnabled else { return dto }
        let decoded = TypedReply.decode(from: dto.reconstructedText)
        dto.structuredSchemaJSON = TypedReply.schemaJSON()
        dto.structuredParsedJSON = decoded.parsedJSON
        dto.structuredError = decoded.error
        return dto
    }

    private static func nextTurnIndex(for transcript: [TranscriptItem]) -> Int {
        transcript.compactMap { item -> Int? in
            guard case let .assistant(_, turn) = item else { return nil }
            return turn.turnIndex
        }.max().map { $0 + 1 } ?? 0
    }
}
