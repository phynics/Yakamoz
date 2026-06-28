import Foundation
import Testing
@testable import YakamozCore

@Suite("AssistantMarkdownRenderer")
struct AssistantMarkdownRendererTests {
    @Test("Native rendering projects common markdown into attributed text")
    func nativeRenderingProjectsMarkdown() {
        let rendered = AssistantMarkdownRenderer().render(
            "Hello **world** [Docs](https://example.com)"
        )

        #expect(String(rendered.characters) == "Hello world Docs")
        #expect(
            rendered.runs.contains { run in
                String(rendered[run.range].characters) == "Docs"
                    && run.link == URL(string: "https://example.com")
            }
        )
    }

    @Test("Fallback returns plain text unchanged when markdown parsing fails")
    func fallbackReturnsPlainTextOnFailure() {
        let source = "```swift\nlet answer = 42"
        let renderer = AssistantMarkdownRenderer(parse: { _ in
            throw StubError.parseFailed
        })

        let rendered = renderer.render(source)

        #expect(String(rendered.characters) == source)
    }
}

private enum StubError: Error {
    case parseFailed
}
