import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transactions: [Transaction]
    let selectedAccount: Account?

    private var monthlyIncome: Int64 {
        transactions
            .filter { $0.type == .income }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthlyExpense: Int64 {
        transactions
            .filter { $0.type == .expense }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "Доходы",
                formattedAmount: appViewModel.currencyManager.formatAmount(monthlyIncome.displayAmount),
                icon: "arrow.up.right",
                color: .green
            )

            SummaryCard(
                title: "Расходы",
                formattedAmount: appViewModel.currencyManager.formatAmount(monthlyExpense.displayAmount),
                icon: "arrow.down.left",
                color: .red
            )
        }
    }
}

struct SummaryCard: View {
    let title: String
    let formattedAmount: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(formattedAmount)
                .font(.headline)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
