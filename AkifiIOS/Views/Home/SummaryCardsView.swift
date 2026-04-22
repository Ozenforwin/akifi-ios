import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transactions: [Transaction]
    let selectedAccount: Account?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var currentMonthTransactions: [Transaction] {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let df = Self.dateFormatter
        return transactions.filter { tx in
            guard let d = df.date(from: tx.date) else { return false }
            return d >= monthStart
        }
    }

    // ADR-001: aggregate via dataStore.amountInBase so VND/EUR/USD rows
    // on differently-denominated accounts get FX-normalized into the user's
    // base currency. Summing `tx.amount` directly lets a 76 000 ₫ row
    // appear as 76 000 ₽ (the original multi-currency bug).
    private var monthlyIncome: Int64 {
        currentMonthTransactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(0) { $0 + appViewModel.dataStore.amountInBase($1) }
    }

    private var monthlyExpense: Int64 {
        currentMonthTransactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(0) { $0 + appViewModel.dataStore.amountInBase($1) }
    }

    var body: some View {
        HStack(spacing: 8) {
            SummaryCard(
                title: String(localized: "summary.monthlyIncome"),
                formattedAmount: "+\(appViewModel.currencyManager.formatAmount(monthlyIncome.displayAmount))",
                systemIcon: "arrow.up.right",
                iconColor: Color.income,
                amountColor: Color.income
            )

            SummaryCard(
                title: String(localized: "summary.monthlyExpense"),
                formattedAmount: "-\(appViewModel.currencyManager.formatAmount(monthlyExpense.displayAmount))",
                systemIcon: "arrow.down.left",
                iconColor: Color.expense,
                amountColor: Color.expense
            )
        }
    }
}

struct SummaryCard: View {
    let title: String
    let formattedAmount: String
    let systemIcon: String
    let iconColor: Color
    let amountColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Icon in colored square (matches HTML design)
                Image(systemName: systemIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(formattedAmount)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(amountColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
