import Foundation
import PKContracts
import PositronicKit

/// Keeps the older Monad-mode test and transport vocabulary at Yakamoz's boundary while
/// the local runtime uses PositronicKit v4's canonical `threadID` spelling.
public extension TurnRequest {
    init(
        timelineId: UUID,
        requestID: UUID? = nil,
        message: String,
        tools: [any Tool] = [],
        toolOutputs: [ToolOutputSubmission]? = nil,
        systemInstructions: String? = nil,
        maxModelRounds: Int = 5,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            threadID: timelineId,
            requestID: requestID,
            message: message,
            tools: tools,
            toolOutputs: toolOutputs,
            systemInstructions: systemInstructions,
            maxModelRounds: maxModelRounds,
            generationParameters: generationParameters
        )
    }

    var timelineId: UUID { threadID }
}
