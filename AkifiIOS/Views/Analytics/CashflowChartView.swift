import SwiftUI
import Charts

/// Bar chart of incomes vs expenses bucketed within the user-selected
/// period. Buckets are sub-month (day / week) for short windows, so this
/// widget can't be served from `monthlyAggregates`; the bucketing is
/// memoized in `AnalyticsTabState.cashflowPoints` (keyed by data revision,
/// account and period) and read once per body.
struct CashflowChartView: View {
    let state: AnalyticsTabState

    var body: some View {
        let points = state.cashflowPoints
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "analytics.cashflow"))
                .font(.headline)

            if points.isEmpty {
                ContentUnavailableView(String(localized: "common.noData"), systemImage: "chart.bar")
                    .frame(height: 200)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.income)
                    )
                    .foregroundStyle(.green.gradient)
                    .position(by: .value("type", String(localized: "common.incomes")))

                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.expense)
                    )
                    .foregroundStyle(.red.gradient)
                    .position(by: .value("type", String(localized: "common.expenses")))
                }
                .chartForegroundStyleScale([
                    String(localized: "common.incomes"): Color.green,
                    String(localized: "common.expenses"): Color.red
                ])
                .frame(height: 220)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
