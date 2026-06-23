import Foundation
import Testing
@testable import YakamozCore

@Suite("DemoTools")
struct DemoToolsTests {
    // MARK: - CalculatorTool

    @Test("Respects operator precedence")
    func precedence() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "2 + 3 * 4"])
        #expect(result.success)
        #expect(result.output == "14")
    }

    @Test("Handles parentheses")
    func parentheses() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "(2 + 3) * 4"])
        #expect(result.success)
        #expect(result.output == "20")
    }

    @Test("Handles unary minus")
    func unaryMinus() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "-3 + 5"])
        #expect(result.success)
        #expect(result.output == "2")
    }

    @Test("Handles decimals")
    func decimals() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "1.5 + 2.25"])
        #expect(result.success)
        #expect(result.output == "3.75")
    }

    @Test("Division precedence over addition")
    func divisionPrecedence() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "10 - 4 / 2"])
        #expect(result.success)
        #expect(result.output == "8")
    }

    @Test("Division by zero throws/fails")
    func divisionByZero() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "1 / 0"])
        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Invalid expression fails cleanly")
    func invalidExpression() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "2 + * 3"])
        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Unbalanced parentheses fails cleanly")
    func unbalancedParens() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "(2 + 3"])
        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Missing expression argument fails cleanly")
    func missingArgument() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: [:])
        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Never shells out or evals — pure parser handles nested expression")
    func nestedExpression() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(parameters: ["expression": "((1 + 2) * (3 - 1)) / 2"])
        #expect(result.success)
        #expect(result.output == "3")
    }

    // MARK: - CurrentDateTimeTool

    @Test("Fixed clock produces expected ISO-8601 string")
    func fixedClockISO8601() async throws {
        let fixedDate = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00Z
        let tool = CurrentDateTimeTool(now: { fixedDate })
        let result = try await tool.execute(parameters: [:])
        #expect(result.success)
        #expect(result.output == "1970-01-01T00:00:00Z")
    }

    @Test("Another fixed clock value formats correctly")
    func anotherFixedClock() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let tool = CurrentDateTimeTool(now: { fixedDate })
        let result = try await tool.execute(parameters: [:])
        #expect(result.success)

        let formatter = ISO8601DateFormatter()
        let expected = formatter.string(from: fixedDate)
        #expect(result.output == expected)
    }

    @Test("Tool ids are stable and unique")
    func toolIdentity() {
        let calc = CalculatorTool()
        let dateTime = CurrentDateTimeTool()
        #expect(calc.id != dateTime.id)
        #expect(!calc.id.isEmpty)
        #expect(!dateTime.id.isEmpty)
    }
}
