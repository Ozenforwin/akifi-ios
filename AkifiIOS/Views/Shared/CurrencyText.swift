import SwiftUI

struct CurrencyText: View {
    @Environment(AppViewModel.self) private var appViewModel
    let amount: Int64
    var signed: Bool = false
    var font: Font = .body
    var color: Color?

    var body: some View {
        let formatted = appViewModel.currencyManager.formatAmount(amount.displayAmount)
        let prefix = signed && amount > 0 ? "+" : signed && amount < 0 ? "-" : ""
        let displayColor = color ?? (signed ? (amount >= 0 ? .green : .red) : .primary)

        Text("\(prefix)\(formatted)")
            .font(font)
            .foregroundStyle(displayColor)
    }
}
