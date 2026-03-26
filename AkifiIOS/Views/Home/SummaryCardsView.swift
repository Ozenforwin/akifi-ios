import SwiftUI

struct SummaryCardsView: View {
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
                amount: monthlyIncome,
                icon: "arrow.up.right",
                color: .green
            )

            SummaryCard(
                title: "Расходы",
                amount: monthlyExpense,
                icon: "arrow.down.left",
                color: .red
            )
        }
    }
}

struct SummaryCard: View {
    let title: String
    let amount: Int64
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

            Text(formatAmount(amount))
                .font(.headline)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func formatAmount(_ amount: Int64) -> String {
        let value = Double(amount) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return "$\(formatter.string(from: NSNumber(value: value)) ?? "0")"
    }
}
