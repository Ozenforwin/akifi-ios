import SwiftUI

struct MonthlySummaryView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        // Side by side; stacked at accessibility text sizes.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(spacing: 12) {
            layout {
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
            .fixedSize(horizontal: false, vertical: true)

            // Net income — a small row-like card.
            let net = currentMonthTotals.income - currentMonthTotals.expense
            HStack {
                Text(String(localized: "analytics.net"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appViewModel.currencyManager.formatAmount(net))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(net >= 0 ? Color.income : Color.expense)
            }
            .akifiCard(.compact)
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryCard(title: String, amount: Decimal, change: Int?, isIncome: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let change {
                    let color = Self.changeBadgeColor(change: change, isIncome: isIncome)
                    Label {
                        Text(verbatim: "\(abs(change))%")
                    } icon: {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
                }
            }

            Text(appViewModel.currencyManager.formatAmount(amount))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .akifiCard()
        .accessibilityElement(children: .combine)
    }

    /// Income up / expenses down is good (income colour), the opposite is
    /// bad (expense colour).
    nonisolated static func changeBadgeColor(change: Int, isIncome: Bool) -> Color {
        let isGood = isIncome ? change >= 0 : change < 0
        return isGood ? Color.income : Color.expense
    }
}
