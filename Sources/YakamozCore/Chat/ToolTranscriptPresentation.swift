import Foundation

/// One ordered, renderable chunk of an assistant turn's transcript (UIX-4): either a
/// markdown text chunk or a reference to a tool's trace. Projects `ChatTurnState.turnSegments`
/// (when present) into a form `MessageBubble` can render in order; falls back to
/// whole-text-then-all-tools when segments aren't available (e.g. turns reloaded from
/// persistence, which don't restore tool traces — STAB-3).
public enum TranscriptRowSegment: Equatable, Sendable {
    case text(String)
    case tool(ToolTrace)
}

public enum TurnTranscriptProjection {
    /// Projects a turn's chronological `turnSegments` into renderable rows, resolving each
    /// `.tool(id:)` marker against `turn.tools`. Returns `nil` when the turn has no
    /// `turnSegments` recorded at all (the reload/no-history fallback case) so callers can
    /// degrade to the legacy append-at-end rendering rather than showing an empty turn.
    public static func segments(for turn: ChatTurnState) -> [TranscriptRowSegment]? {
        guard !turn.turnSegments.isEmpty else { return nil }

        return turn.turnSegments.compactMap { segment in
            switch segment {
            case let .text(text):
                return text.isEmpty ? nil : .text(text)
            case let .tool(id):
                guard let trace = turn.tools[id] else { return nil }
                return .tool(trace)
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

    public var fullParameters: String {
        trace.arguments ?? ""
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
        let parameters = Self.parameterPairs(from: trace.arguments)
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
