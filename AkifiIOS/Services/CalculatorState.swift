import Foundation

@Observable @MainActor
final class CalculatorState {
    var expression = ""
    var displayValue = "0"
    var currentResult: Decimal?
    var isComplete = false

    var hasExpression: Bool {
        expression.contains(where: { "+-×÷".contains($0) })
    }

    func handleDigit(_ digit: String) {
        if isComplete {
            expression = ""
            isComplete = false
        }
        expression += digit
        updateDisplay()
    }

    func handleOperator(_ op: CalcOperator) {
        if isComplete {
            isComplete = false
        }
        // Don't allow operator at start (except minus)
        if expression.isEmpty && op != .subtract { return }
        // Don't allow two operators in a row (replace last)
        if let last = expression.last, "+-×÷".contains(last) {
            expression.removeLast()
        }
        expression += op.symbol
        updateDisplay()
    }

    private static let decimalSeparator = Locale.current.decimalSeparator ?? ","

    func handleDecimal() {
        if isComplete {
            expression = "0"
            isComplete = false
        }
        // Find current number segment
        let sep = Self.decimalSeparator
        let parts = expression.split(omittingEmptySubsequences: false) { "+-×÷".contains($0) }
        if let lastPart = parts.last, lastPart.contains(sep) {
            return // Already has decimal
        }
        if expression.isEmpty || (expression.last.map { "+-×÷".contains($0) } ?? true) {
            expression += "0"
        }
        expression += sep
        updateDisplay()
    }

    func handleBackspace() {
        if isComplete {
            expression = ""
            isComplete = false
            updateDisplay()
            return
        }
        guard !expression.isEmpty else { return }
        expression.removeLast()
        updateDisplay()
    }

    func handleClear() {
        expression = ""
        displayValue = "0"
        currentResult = nil
        isComplete = false
    }

    func handleEquals() {
        guard !expression.isEmpty else { return }
        // Strip trailing operator
        var expr = expression
        while let last = expr.last, "+-×÷".contains(last) {
            expr.removeLast()
        }
        guard !expr.isEmpty else { return }
        if let result = evaluate(expr) {
            currentResult = result
            displayValue = formatResult(result)
            expression = displayValue.replacingOccurrences(of: " ", with: "")
            isComplete = true
        }
    }

    func setValue(_ value: Decimal) {
        let formatted = formatResult(value)
        expression = formatted.replacingOccurrences(of: " ", with: "")
        displayValue = formatted
        currentResult = value
        isComplete = true
    }

    func getResult() -> Decimal? {
        if let result = currentResult {
            return result
        }
        return evaluate(expression)
    }

    // MARK: - Expression Evaluation

    private func evaluate(_ expr: String) -> Decimal? {
        let normalized = expr
            .replacingOccurrences(of: Self.decimalSeparator, with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        var tokens: [Token] = []
        var currentNumber = ""

        let chars = Array(normalized)
        for (i, char) in chars.enumerated() {
            let prevIsOperator = i > 0 && "+-×÷".contains(chars[i - 1])
            if char.isNumber || char == "." || (char == "-" && i == 0) || (char == "-" && prevIsOperator) {
                currentNumber.append(char)
            } else if "+-×÷".contains(char) {
                if !currentNumber.isEmpty {
                    guard let num = Decimal(string: currentNumber) else { return nil }
                    tokens.append(.number(num))
                    currentNumber = ""
                }
                tokens.append(.op(char))
            }
        }
        if !currentNumber.isEmpty {
            guard let num = Decimal(string: currentNumber) else { return nil }
            tokens.append(.number(num))
        }

        guard !tokens.isEmpty else { return nil }

        // Evaluate with operator precedence: ×÷ first, then +-
        return evaluateTokens(tokens)
    }

    private func evaluateTokens(_ tokens: [Token]) -> Decimal? {
        // First pass: handle × and ÷
        var simplified: [Token] = []
        var i = 0
        while i < tokens.count {
            if case .op(let op) = tokens[i], (op == "×" || op == "÷") {
                guard let left = simplified.last, case .number(let lv) = left else { return nil }
                i += 1
                guard i < tokens.count, case .number(let rv) = tokens[i] else { return nil }
                simplified.removeLast()
                if op == "×" {
                    simplified.append(.number(lv * rv))
                } else {
                    guard rv != 0 else { return nil } // Division by zero
                    simplified.append(.number(lv / rv))
                }
            } else {
                simplified.append(tokens[i])
            }
            i += 1
        }

        // Second pass: handle + and -
        guard !simplified.isEmpty, case .number(var result) = simplified[0] else { return nil }
        i = 1
        while i < simplified.count {
            guard case .op(let op) = simplified[i] else { return nil }
            i += 1
            guard i < simplified.count, case .number(let rv) = simplified[i] else { return nil }
            if op == "+" {
                result += rv
            } else if op == "-" {
                result -= rv
            }
            i += 1
        }

        return result
    }

    private enum Token {
        case number(Decimal)
        case op(Character)
    }

    // MARK: - Display

    private func updateDisplay() {
        if expression.isEmpty {
            displayValue = "0"
            currentResult = nil
            return
        }

        // Try to evaluate current expression for live preview
        let normalized = expression
            .replacingOccurrences(of: Self.decimalSeparator, with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        if let result = evaluate(normalized) {
            currentResult = result
        }

        displayValue = expression
    }

    private func formatResult(_ value: Decimal) -> String {
        let nsNumber = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale.current
        formatter.groupingSeparator = " "
        return formatter.string(from: nsNumber) ?? "\(value)"
    }
}

enum CalcOperator: Sendable {
    case add, subtract, multiply, divide

    var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "×"
        case .divide: return "÷"
        }
    }

    var display: String { symbol }
}
