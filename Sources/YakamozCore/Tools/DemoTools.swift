import Foundation
import JSONSchemaBuilder
import PKShared

/// Errors produced by `CalculatorTool`'s hand-written recursive-descent parser.
public enum CalculatorError: PKError, Sendable, Equatable {
    case divisionByZero
    case invalidExpression(String)

    public var errorDomain: String {
        PKErrorDomain.tool
    }

    public var errorCode: Int {
        switch self {
        case .divisionByZero: return 901
        case .invalidExpression: return 902
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .divisionByZero:
            return "Division by zero is undefined."
        case let .invalidExpression(detail):
            return "The expression could not be evaluated: \(detail)"
        }
    }
}

/// A deterministic, pure arithmetic calculator tool.
///
/// Implements its own recursive-descent parser supporting decimals, parentheses, unary
/// minus, and `+ - * /` with standard precedence. Never shells out, never uses
/// `NSExpression`, and never evaluates JavaScript — every character is parsed by hand so
/// the tool's behavior is fully auditable and sandboxed.
public struct CalculatorTool: Tool, Sendable {
    public let id = "calculator"
    public let name = "Calculator"
    public let description = "Evaluates a basic arithmetic expression (+, -, *, /, parentheses, decimals)."
    public let requiresPermission = false

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "calculator", "arguments": {"expression": "(2 + 3) * 4"}}
        </tool_call>
        """
    }

    public init() {}

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "expression") {
                JSONString().description("The arithmetic expression to evaluate, e.g. '2 + 3 * 4'")
            }
            .required()
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let expression: String
        do {
            expression = try params.require("expression", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        do {
            var parser = ArithmeticParser(expression)
            let value = try parser.parse()
            return .success(Self.format(value))
        } catch let error as CalculatorError {
            return .failure(error.userFriendlyMessage)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Formats a `Double` result, dropping the trailing `.0` for whole numbers so output
    /// reads naturally (e.g. "14" rather than "14.0").
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        // Trim trailing zeros for non-integral results while keeping precision.
        var string = String(format: "%.10f", value)
        while string.hasSuffix("0") {
            string.removeLast()
        }
        if string.hasSuffix(".") {
            string.removeLast()
        }
        return string
    }
}

/// Hand-written recursive-descent parser/evaluator for a small arithmetic grammar:
///
/// ```text
/// expression := term (('+' | '-') term)*
/// term       := factor (('*' | '/') factor)*
/// factor     := '-' factor | '(' expression ')' | number
/// ```
///
/// Operates purely on `Double` values in memory; never touches the filesystem, a shell,
/// or any interpreter. Throws `CalculatorError` for malformed input or division by zero.
struct ArithmeticParser {
    private let scalars: [Character]
    private var index = 0

    init(_ expression: String) {
        scalars = Array(expression)
    }

    mutating func parse() throws -> Double {
        skipWhitespace()
        let value = try parseExpression()
        skipWhitespace()
        guard index == scalars.count else {
            throw CalculatorError.invalidExpression("Unexpected trailing characters at position \(index)")
        }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "+" || op == "-" else { break }
            advance()
            let rhs = try parseTerm()
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "*" || op == "/" else { break }
            advance()
            let rhs = try parseFactor()
            if op == "*" {
                value *= rhs
            } else {
                guard rhs != 0 else { throw CalculatorError.divisionByZero }
                value /= rhs
            }
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        skipWhitespace()
        guard let char = peek() else {
            throw CalculatorError.invalidExpression("Unexpected end of expression")
        }

        if char == "-" {
            advance()
            return try -parseFactor()
        }
        if char == "+" {
            advance()
            return try parseFactor()
        }
        if char == "(" {
            advance()
            let value = try parseExpression()
            skipWhitespace()
            guard let closing = peek(), closing == ")" else {
                throw CalculatorError.invalidExpression("Missing closing parenthesis")
            }
            advance()
            return value
        }

        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        var sawDigit = false
        var sawDot = false

        while let char = peek() {
            if char.isNumber {
                sawDigit = true
                advance()
            } else if char == ".", !sawDot {
                sawDot = true
                advance()
            } else {
                break
            }
        }

        guard sawDigit else {
            throw CalculatorError.invalidExpression("Expected a number at position \(start)")
        }

        let text = String(scalars[start ..< index])
        guard let value = Double(text) else {
            throw CalculatorError.invalidExpression("Malformed number '\(text)'")
        }
        return value
    }

    private func peek() -> Character? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func skipWhitespace() {
        while let char = peek(), char.isWhitespace {
            advance()
        }
    }
}

/// A deterministic tool that reports the current date/time as an ISO-8601 string.
///
/// `now` is injected (defaulting to `Date.init` in production) so tests can supply a
/// fixed clock and assert an exact, reproducible output string.
public struct CurrentDateTimeTool: Tool, Sendable {
    public let id = "current_datetime"
    public let name = "Current Date/Time"
    public let description = "Returns the current date and time as an ISO-8601 string."
    public let requiresPermission = false

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "current_datetime", "arguments": {}}
        </tool_call>
        """
    }

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func canExecute() async -> Bool {
        true
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {}.schema
    }

    public func execute(parameters _: [String: Any]) async throws -> ToolResult {
        let formatter = ISO8601DateFormatter()
        return .success(formatter.string(from: now()))
    }
}
