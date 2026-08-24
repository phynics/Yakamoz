import ErrorKit
import Foundation
import Observation
import PKContracts
import PositronicKit

/// YAK-MON-7: main-actor view model driving a Monad-mode chat conversation. Wraps a
/// `ChatViewModel` constructed with a `ChatRunning` runner (typically
/// `MonadYakamozBackend`), with no `SwiftDataPromptInspector` — the server is
/// authoritative for Monad-mode conversations, so nothing is persisted locally.
///
/// The underlying `ChatViewModel` already handles streaming via `ChatEventReducer`,
/// surfaces errors via `ErrorKit.userFriendlyMessage(for:)` (which covers
/// `MonadBackendHealthError` through its `LocalizedError` conformance), handles
/// cancellation, and manages empty/partial turns. This wrapper provides the
/// Monad-mode construction seam and integrates workspace display state.
@MainActor
@Observable
public final class MonadChatViewModel {
    public let chatViewModel: ChatViewModel
    public var workspaceViewModel: MonadWorkspaceViewModel?

    public init(
        timelineId: UUID,
        runner: any ChatRunning,
        systemInstructions: String? = nil
    ) {
        chatViewModel = ChatViewModel(
            timelineId: timelineId,
            runner: runner,
            inspector: nil,
            systemInstructions: systemInstructions
        )
    }

    public func send(_ text: String) {
        chatViewModel.send(text)
    }

    public func cancel() {
        chatViewModel.cancel()
    }

    public func retryFailedTurn(errorId: UUID) {
        chatViewModel.retryFailedTurn(errorId: errorId)
    }

    public func awaitSendCompletion() async {
        await chatViewModel.awaitSendCompletion()
    }
}
