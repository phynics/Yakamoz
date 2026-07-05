import Foundation

/// One ordered, renderable chunk of an assistant turn's transcript (UIX-4): either a
/// markdown text chunk or a reference to a tool's trace. Projects `ChatTurnState.turnSegments`
/// (when present) into a form `MessageBubble` can render in order; falls back to
/// whole-text-then-all-tools when segments aren't available (e.g. turns reloaded from
/// persistence, which don't restore tool traces — STAB-3).
public enum TranscriptRowSegment: Equatable, Sendable {
    case text(String)
    case tool(ToolTrace)
    /// A chronologically-positioned reasoning/thinking chunk (UIX-7). Rendered as its own
    /// collapsible disclosure at its position in segment order, rather than only ever
    /// appearing once at the top of the turn. `isStreaming` (UIX-9) is true exactly when
    /// this segment is still actively receiving deltas — it is the turn's trailing segment
    /// and the turn hasn't completed — so the view can auto-expand it while live and
    /// auto-collapse it once content follows (a text/tool segment appears after it, or the
    /// turn completes), unless the user has manually overridden that segment's expansion.
    case thinking(String, isStreaming: Bool)
}

public enum TurnTranscriptProjection {
    /// Projects a turn's chronological `turnSegments` into renderable rows, resolving each
    /// `.tool(id:)` marker against `turn.tools`. Returns `nil` when the turn has no
    /// `turnSegments` recorded at all (the reload/no-history fallback case) so callers can
    /// degrade to the legacy append-at-end rendering rather than showing an empty turn.
    public static func segments(for turn: ChatTurnState) -> [TranscriptRowSegment]? {
        guard !turn.turnSegments.isEmpty else { return nil }

        let lastIndex = turn.turnSegments.count - 1
        return turn.turnSegments.enumerated().compactMap { index, segment in
            switch segment {
            case let .text(text):
                return text.isEmpty ? nil : .text(text)
            case let .tool(id):
                guard let trace = turn.tools[id] else { return nil }
                return .tool(trace)
            case let .thinking(thought):
                guard !thought.isEmpty else { return nil }
                // UIX-9: a thinking segment is still "live" only while it is the turn's
                // trailing segment (nothing has started after it yet) and the turn hasn't
                // reached its terminal state. Any earlier thinking segment — one that a
                // later text/tool/thinking segment already follows — is never streaming,
                // even if the turn overall is still in progress.
                let isStreaming = index == lastIndex && !turn.isComplete
                return .thinking(thought, isStreaming: isStreaming)
            }
        }
    }
}

public enum ToolTranscriptStatus: Equatable, Sendable {
    case attempting
    case success
    case failure
}

public struct ToolTranscriptPresentation: Equatable, Sendable {
    public let trace: ToolTrace

    public init(trace: ToolTrace) {
        self.trace = trace
    }

    public var status: ToolTranscriptStatus {
        switch trace.state {
        case .attempting:
            .attempting
        case .succeeded:
            .success
        case .failed:
            .failure
        }
    }

    public var detailTitle: String {
        trace.name
    }

    /// TEX-2: the model-authored `explanation` argument (TEX-1), rendered as a caption —
    /// excluded from `fullParameters`/`notation` (see `ToolCallExplanation`). `nil` while
    /// unavailable/absent/blank/non-string, including on a still-partial streaming JSON
    /// fragment, so callers render nothing rather than a placeholder.
    public var explanationText: String? {
        ToolCallExplanation.explanationText(fromArguments: trace.arguments)
    }

    public var fullParameters: String {
        ToolCallExplanation.displayArguments(fromArguments: trace.arguments) ?? ""
    }

    public var fullResponse: String {
        if let error = trace.error, !error.isEmpty {
            return error
        }
        if let output = trace.output, !output.isEmpty {
            return output
        }
        return ""
    }

    public var notation: String {
        let params = formattedParameters()
        let result = Self.truncated(resultSummary, limit: Self.resultSummaryLimit)
        return "\(trace.name)(\(params)) -> \(result)"
    }

    private var resultSummary: String {
        let response = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            return trace.state == .attempting ? "running" : "no output"
        }
        return response.replacingOccurrences(of: "\n", with: "\\n")
    }

    private func formattedParameters() -> String {
        let parameters = Self.parameterPairs(from: ToolCallExplanation.displayArguments(fromArguments: trace.arguments))
        return parameters.map { key, value in
            "\(key): \(Self.truncated(value, limit: Self.parameterValueLimit))"
        }.joined(separator: ", ")
    }

    private static let parameterValueLimit = 60
    private static let resultSummaryLimit = 77

    private static func parameterPairs(from arguments: String?) -> [(String, String)] {
        guard let arguments,
              !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return [("arguments", arguments)]
        }

        return dictionary.keys.sorted().map { key in
            (key, displayValue(dictionary[key] ?? ""))
        }
    }

    private static func displayValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string.replacingOccurrences(of: "\n", with: "\\n")
        case let number as NSNumber:
            return number.stringValue
        case _ as NSNull:
            return "null"
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return String(describing: value)
            }
            return string
        }
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "..."
    }
}
