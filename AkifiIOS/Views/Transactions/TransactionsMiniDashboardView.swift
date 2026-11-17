import SwiftUI
import Charts

struct TransactionsMiniDashboardView: View {
    let transactions: [Transaction]
    var onOpenReports: () -> Void

    @Environment(AppViewModel.self) private var appVM

    private struct MonthsKey: Equatable {
        let transactions: ArrayIdentity<Transaction>
        let token: UInt64
        let currentMonth: String
    }

    /// Six months of income / expense, computed once per data revision.
    /// It used to be rebuilt by every reader — the chart, `maxValue` and
    /// each x-axis label — i.e. ~8 × 6 × N FX conversions per render.
    @State private var memo = Memo<MonthsKey, [MiniDashboardMonth]>()

    var body: some View {
        let store = appVM.dataStore
        let key = MonthsKey(
            transactions: ArrayIdentity(transactions),
            token: store.txGenerationToken,
            currentMonth: DayKey.month(Date())
        )
        let monthlyData = memo.value(for: key) {
            Self.months(transactions, amountInBase: { store.amountInBase($0) })
        }
        let currentLabels = Set(monthlyData.filter(\.isCurrent).map(\.label))
        VStack(alignment: .leading, spacing: 8) {
            Chart(monthlyData) { entry in
                BarMark(
                    x: .value(String(localized: "chart.month"), entry.label),
                    y: .value(String(localized: "chart.amount"), entry.income)
                )
                .foregroundStyle(Color.income)
                .position(by: .value(String(localized: "chart.type"), "income"))

                BarMark(
                    x: .value(String(localized: "chart.month"), entry.label),
                    y: .value(String(localized: "chart.amount"), entry.expense)
                )
                .foregroundStyle(Color.expense)
                .position(by: .value(String(localized: "chart.type"), "expense"))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(abbreviate(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            let isCurrent = currentLabels.contains(label)
                            Text(label)
                                .font(.caption2)
                                .fontWeight(isCurrent ? .bold : .regular)
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 120)

            Button(action: onOpenReports) {
                Text(String(localized: "dashboard.expenseOverview"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accent)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func abbreviate(_ value: Double) -> String {
        if value >= 1_000_000 { return "\(Int(value / 1_000_000))M" }
        if value >= 1_000 { return "\(Int(value / 1_000))k" }
        return "\(Int(value))"
    }

    /// Last six calendar months (oldest first) of non-transfer income /
    /// expense in base currency, in a single pass over `transactions`.
    /// ADR-001: every row is FX-normalized via `amountInBase` before summing.
    static func months(
        _ transactions: [Transaction],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        amountInBase: (Transaction) -> Int64
    ) -> [MiniDashboardMonth] {
        let keys = DayKey.recentMonths(6, now: now, timeZone: timeZone)
        let window = Set(keys)
        var income: [String: Int64] = [:]
        var expense: [String: Int64] = [:]
        for tx in transactions where !tx.isTransfer {
            let key = String(tx.date.prefix(7))
            guard window.contains(key) else { continue }
            switch tx.type {
            case .income: income[key, default: 0] += amountInBase(tx)
            case .expense: expense[key, default: 0] += amountInBase(tx)
            case .transfer: break
            }
        }
        let currentKey = keys.last
        return keys.map { key in
            MiniDashboardMonth(
                id: key,
                label: shortLabel(forMonthKey: key),
                income: Double(income[key] ?? 0) / 100,
                expense: Double(expense[key] ?? 0) / 100,
                isCurrent: key == currentKey
            )
        }
    }

    private static func shortLabel(forMonthKey key: String) -> String {
        switch Int(key.suffix(2)) ?? 0 {
        case 1: String(localized: "month.jan")
        case 2: String(localized: "month.feb")
        case 3: String(localized: "month.mar")
        case 4: String(localized: "month.apr")
        case 5: String(localized: "month.may")
        case 6: String(localized: "month.jun")
        case 7: String(localized: "month.jul")
        case 8: String(localized: "month.aug")
        case 9: String(localized: "month.sep")
        case 10: String(localized: "month.oct")
        case 11: String(localized: "month.nov")
        case 12: String(localized: "month.dec")
        default: ""
        }
    }
}

struct MiniDashboardMonth: Identifiable, Equatable {
    /// "yyyy-MM" — stable across recomputes (a fresh `UUID()` per render
    /// made the chart rebuild every bar).
    let id: String
    let label: String
    let income: Double
    let expense: Double
    let isCurrent: Bool
}
