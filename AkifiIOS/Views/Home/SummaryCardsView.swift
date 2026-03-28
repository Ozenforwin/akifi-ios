import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transactions: [Transaction]
    let selectedAccount: Account?

    private var monthlyIncome: Int64 {
        transactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthlyExpense: Int64 {
        transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        HStack(spacing: 8) {
            SummaryCard(
                title: "Доходы за месяц",
                formattedAmount: "+\(appViewModel.currencyManager.formatAmount(monthlyIncome.displayAmount))",
                systemIcon: "arrow.up.right",
                iconColor: Color.income,
                amountColor: Color.income
            )

            SummaryCard(
                title: "Расходы за месяц",
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
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
