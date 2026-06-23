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

    private var sendTask: Task<Void, Never>?
    private let runner: any ChatRunning
    private let inspector: SwiftDataTurnInspector?
    private let timelineId: UUID
    private let agentInstanceId: UUID?
    private let tools: [AnyTool]
    private let systemInstructions: String?
    private let maxTurns: Int
    private let generationParameters: GenerationParameters?
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
            await self?.consume(trimmed)
        }
    }

    /// Cancels the in-flight turn, if any. The underlying stream observes task
    /// cancellation; `consume` records `isCancelled` on the in-progress turn state
    /// when the loop is interrupted this way.
    public func cancel() {
        sendTask?.cancel()
    }

    private func consume(_ text: String) async {
        let turnIndex = nextTurnIndex
        nextTurnIndex += 1

        var state = ChatTurnState(turnIndex: turnIndex)
        let assistantItemId = UUID()
        transcript.append(.assistant(id: assistantItemId, turn: state))
        selectedTurnIndex = turnIndex

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

                if let message = state.errorMessage {
                    errorMessage = message
                }
            }

            if Task.isCancelled, !state.isCancelled {
                state.isCancelled = true
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
            updateAssistantItem(id: assistantItemId, turn: state)
        }
    }

    private func updateAssistantItem(id: UUID, turn: ChatTurnState) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index] = .assistant(id: id, turn: turn)
    }

    private func persistResponse(turnIndex: Int, state: ChatTurnState) async {
        guard let inspector else { return }
        do {
            try await inspector.updateResponse(
                conversationId: timelineId,
                turnIndex: turnIndex,
                response: state.responseDTO
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
