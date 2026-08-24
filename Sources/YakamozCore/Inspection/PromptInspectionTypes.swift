import Foundation
import PKContracts
import PKPrompt

/// Yakamoz's persisted prompt-inspection input. PositronicKit v4 intentionally keeps prompt
/// assembly internals private, so the showcase records the public request and rendered prompt
/// projection at its own boundary instead of conforming to the removed upstream inspector hook.
public struct TurnJournalSnapshot: Sendable {
    public let overlay: PromptJournalDiff
    public let stablePrefixCount: Int
    public let didCompact: Bool

    public init(
        overlay: PromptJournalDiff,
        stablePrefixCount: Int,
        didCompact: Bool
    ) {
        self.overlay = overlay
        self.stablePrefixCount = stablePrefixCount
        self.didCompact = didCompact
    }
}

public struct PromptInspection: Sendable {
    public let threadID: UUID
    public let agentID: UUID?
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt
    public let sentMessages: [LLMMessage]
    public let journal: TurnJournalSnapshot
    public let estimatedTokens: Int
    public let identity: TurnIdentity

    public init(
        threadID: UUID,
        agentID: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int,
        requestID: UUID = UUID()
    ) {
        self.threadID = threadID
        self.agentID = agentID
        self.turnIndex = turnIndex
        self.model = model
        self.rendered = rendered
        self.sentMessages = sentMessages
        self.journal = journal
        self.estimatedTokens = estimatedTokens
        identity = TurnIdentity(
            turnID: UUID(),
            requestID: requestID,
            modelRoundIndex: turnIndex
        )
    }
}
