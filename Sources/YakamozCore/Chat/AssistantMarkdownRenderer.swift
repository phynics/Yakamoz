import Foundation

public struct AssistantMarkdownRenderer {
    public typealias Parser = (String) throws -> AttributedString

    private let parse: Parser

    public init() {
        parse = Self.parseMarkdown
    }

    init(parse: @escaping Parser) {
        self.parse = parse
    }

    public func render(_ source: String) -> AttributedString {
        do {
            return try parse(source)
        } catch {
            return AttributedString(source)
        }
    }

    private static func parseMarkdown(_ source: String) throws -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return try AttributedString(markdown: source, options: options)
    }
}
