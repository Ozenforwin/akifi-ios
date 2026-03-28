import SwiftUI

struct MonthlySummaryView: View {
    @Environment(AppViewModel.self) private var appViewModel

    let transactions: [Transaction]

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var currentMonthTotals: (income: Decimal, expense: Decimal) {
        monthTotals(offset: 0)
    }

    private var previousMonthTotals: (income: Decimal, expense: Decimal) {
        monthTotals(offset: -1)
    }

    private func monthTotals(offset: Int) -> (income: Decimal, expense: Decimal) {
        let cal = Calendar.current
        let now = Date()
        guard let targetMonth = cal.date(byAdding: .month, value: offset, to: now) else {
            return (0, 0)
        }
        let comps = cal.dateComponents([.year, .month], from: targetMonth)
        let df = Self.dateFormatter

        var income: Decimal = 0
        var expense: Decimal = 0
        for tx in transactions {
            guard let date = df.date(from: tx.date) else { continue }
            let txComps = cal.dateComponents([.year, .month], from: date)
            guard txComps.year == comps.year, txComps.month == comps.month else { continue }
            if tx.type == .income { income += tx.amount.displayAmount }
            else if tx.type == .expense { expense += tx.amount.displayAmount }
        }
        return (income, expense)
    }

    private func changePercent(current: Decimal, previous: Decimal) -> Int? {
        guard previous > 0 else { return nil }
        let change = Double(truncating: ((current - previous) / previous * 100) as NSDecimalNumber)
        return Int(change)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Income card
                summaryCard(
                    title: "Доходы",
                    amount: currentMonthTotals.income,
                    change: changePercent(current: currentMonthTotals.income, previous: previousMonthTotals.income),
                    isIncome: true
                )

                // Expense card
                summaryCard(
                    title: "Расходы",
                    amount: currentMonthTotals.expense,
                    change: changePercent(current: currentMonthTotals.expense, previous: previousMonthTotals.expense),
                    isIncome: false
                )
            }

            // Net income
            let net = currentMonthTotals.income - currentMonthTotals.expense
            HStack {
                Text("Нетто")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appViewModel.currencyManager.formatAmount(net))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(net >= 0 ? Color.income : Color.expense)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func summaryCard(title: String, amount: Decimal, change: Int?, isIncome: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let change {
                    HStack(spacing: 2) {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(abs(change))%")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(changeBadgeColor(change: change, isIncome: isIncome))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(changeBadgeColor(change: change, isIncome: isIncome).opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            Text(appViewModel.currencyManager.formatAmount(amount))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func changeBadgeColor(change: Int, isIncome: Bool) -> Color {
        // For income: up is good (green), down is bad (red)
        // For expenses: up is bad (red), down is good (green)
        if isIncome {
            return change >= 0 ? .green : .red
        } else {
            return change >= 0 ? .red : .green
        }
    }
}
