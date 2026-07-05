import Foundation

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
              !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
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
                  let string = String(data: data, encoding: .utf8) else {
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
