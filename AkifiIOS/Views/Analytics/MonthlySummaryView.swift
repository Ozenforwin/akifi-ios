import SwiftUI

struct MonthlySummaryView: View {
    @Environment(AppViewModel.self) private var appViewModel

    /// Pre-computed monthly aggregates in base currency (kopecks),
    /// chronologically sorted (oldest → newest). Last element is the
    /// current month, second-to-last is the previous month. When fewer
    /// than two months are present the missing values fall back to zero.
    let aggregates: [MonthlyAggregate]

    private var currentMonthTotals: (income: Decimal, expense: Decimal) {
        guard let last = aggregates.last else { return (0, 0) }
        return (kopecksToDecimal(last.income), kopecksToDecimal(last.expense))
    }

    private var previousMonthTotals: (income: Decimal, expense: Decimal) {
        guard aggregates.count >= 2 else { return (0, 0) }
        let prev = aggregates[aggregates.count - 2]
        return (kopecksToDecimal(prev.income), kopecksToDecimal(prev.expense))
    }

    /// `MonthlyAggregate` stores values in base-currency kopecks (Int64).
    /// `CurrencyManager.formatAmount(_:)` expects a `Decimal` in major
    /// units, so we convert with the canonical 1/100 factor used by the
    /// rest of the app (kopecks → rubles / cents → dollars / etc).
    private func kopecksToDecimal(_ kopecks: Int64) -> Decimal {
        Decimal(kopecks) / Decimal(100)
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
                    title: String(localized: "common.incomes"),
                    amount: currentMonthTotals.income,
                    change: changePercent(current: currentMonthTotals.income, previous: previousMonthTotals.income),
                    isIncome: true
                )

                // Expense card
                summaryCard(
                    title: String(localized: "common.expenses"),
                    amount: currentMonthTotals.expense,
                    change: changePercent(current: currentMonthTotals.expense, previous: previousMonthTotals.expense),
                    isIncome: false
                )
            }

            // Net income
            let net = currentMonthTotals.income - currentMonthTotals.expense
            HStack {
                Text(String(localized: "analytics.net"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appViewModel.currencyManager.formatAmount(net))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(net >= 0 ? Color.income : Color.expense)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
            )
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
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
