import SwiftUI
import UIKit

struct CalculatorKeyboardView: View {
    @Bindable var state: CalculatorState
    var onComplete: ((Decimal) -> Void)?

    private let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            // Display
            VStack(alignment: .trailing, spacing: 4) {
                if state.hasExpression {
                    Text(state.expression)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(state.displayValue)
                    .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Keyboard grid
            VStack(spacing: spacing) {
                // Row 1: C, ⌫, ÷, ×
                HStack(spacing: spacing) {
                    calcButton("C", style: .destructive) { state.handleClear() }
                    calcButton("⌫", style: .action) { state.handleBackspace() }
                    calcButton("÷", style: .operator) { state.handleOperator(.divide) }
                    calcButton("×", style: .operator) { state.handleOperator(.multiply) }
                }

                // Row 2: 7, 8, 9, −
                HStack(spacing: spacing) {
                    calcButton("7", style: .digit) { state.handleDigit("7") }
                    calcButton("8", style: .digit) { state.handleDigit("8") }
                    calcButton("9", style: .digit) { state.handleDigit("9") }
                    calcButton("−", style: .operator) { state.handleOperator(.subtract) }
                }

                // Row 3: 4, 5, 6, +
                HStack(spacing: spacing) {
                    calcButton("4", style: .digit) { state.handleDigit("4") }
                    calcButton("5", style: .digit) { state.handleDigit("5") }
                    calcButton("6", style: .digit) { state.handleDigit("6") }
                    calcButton("+", style: .operator) { state.handleOperator(.add) }
                }

                // Row 4: 1, 2, 3, =
                HStack(spacing: spacing) {
                    calcButton("1", style: .digit) { state.handleDigit("1") }
                    calcButton("2", style: .digit) { state.handleDigit("2") }
                    calcButton("3", style: .digit) { state.handleDigit("3") }
                    calcButton("=", style: .equals) { state.handleEquals() }
                }

                // Row 5: 00, 0, comma, OK
                HStack(spacing: spacing) {
                    calcButton("00", style: .digit) { state.handleDigit("00") }
                    calcButton("0", style: .digit) { state.handleDigit("0") }
                    calcButton(",", style: .digit) { state.handleDecimal() }
                    calcButton("OK", style: .confirm) {
                        if let result = state.getResult() {
                            onComplete?(result)
                            haptic(.medium)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func calcButton(_ title: String, style: CalcButtonStyle, action: @escaping () -> Void) -> some View {
        Button {
            haptic(style == .equals || style == .confirm ? .medium : .light)
            action()
        } label: {
            Text(title)
                .font(.system(size: style == .confirm ? 16 : 20, weight: style.fontWeight, design: .rounded))
                .foregroundStyle(style.foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(style.backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(CalcButtonPressStyle())
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Button Styles

private enum CalcButtonStyle {
    case digit
    case `operator`
    case action
    case equals
    case confirm
    case destructive

    var backgroundColor: Color {
        switch self {
        case .digit: return Color(.tertiarySystemBackground)
        case .operator: return Color.accent.opacity(0.15)
        case .action: return Color(.tertiarySystemBackground)
        case .equals: return Color.accent.opacity(0.2)
        case .confirm: return Color.accent
        case .destructive: return Color.red.opacity(0.15)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .digit: return .primary
        case .operator: return .accent
        case .action: return .secondary
        case .equals: return .accent
        case .confirm: return .white
        case .destructive: return .red
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .confirm, .equals: return .semibold
        case .operator: return .medium
        default: return .regular
        }
    }
}

private struct CalcButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
