import Foundation
import PKShared
import PositronicKit

/// A `ChatTurnPlugin` that injects at most ONE autonomous follow-up message per user send.
///
/// The chat loop calls `afterTurn(_:)` after every completed turn. Returning a non-empty
/// `[LLMMessage]` makes `ChatTurnFollowUpPolicy` continue the loop for one more turn; returning
/// `[]` lets it finish. This plugin returns a single follow-up the first time it sees a turn for
/// a given send, then returns `[]` for every subsequent turn in that same send — so a send can
/// trigger at most one extra autonomous turn, never an unbounded chain.
///
/// `afterTurn` only ever runs for turns that completed successfully: `ChatTurnFollowUpPolicy`
/// invokes plugins only after a turn's response is accumulated, and the chat loop does not reach
/// the plugin stage on cancellation or error (those tear the stream down first). The per-send
/// guard is reset by the caller via `beginUserSend()` before each new user message, so a fresh
/// send is once again eligible for exactly one follow-up.
public actor AutonomousFollowUpPlugin: ChatTurnPlugin {
    /// The follow-up instruction injected as a user-role message to nudge one more turn.
    public static let defaultFollowUp =
        "Briefly review your previous answer and add any one important caveat or next step you missed. If nothing is missing, say so in one sentence."

    /// Label shown on the transcript divider that introduces the autonomous continuation.
    public static let dividerLabel = "Autonomous follow-up"

    private let followUpText: String
    private var hasFollowedUpThisSend = false

    public init(followUpText: String = AutonomousFollowUpPlugin.defaultFollowUp) {
        self.followUpText = followUpText
    }

    /// Clears the per-send guard. Call this immediately before each new user send so the
    /// next send is eligible for exactly one follow-up again.
    public func beginUserSend() {
        hasFollowedUpThisSend = false
    }

    public func afterTurn(_: CompletedTurn) async throws -> [LLMMessage] {
        guard !hasFollowedUpThisSend else { return [] }
        hasFollowedUpThisSend = true
        return [LLMMessage(role: .user, content: followUpText)]
    }
}
