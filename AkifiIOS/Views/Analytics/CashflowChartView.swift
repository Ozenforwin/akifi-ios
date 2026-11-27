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
                .accessibilityAddTraits(.isHeader)

            if points.isEmpty {
                ContentUnavailableView(String(localized: "common.noData"), systemImage: "chart.bar")
                    .frame(height: 200)
            } else {
                // Semantic colours, solid (the bars had decorative
                // gradients).
                Chart(points) { point in
                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.income)
                    )
                    .foregroundStyle(Color.income)
                    .position(by: .value("type", String(localized: "common.incomes")))

                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.expense)
                    )
                    .foregroundStyle(Color.expense)
                    .position(by: .value("type", String(localized: "common.expenses")))
                }
                .chartForegroundStyleScale([
                    String(localized: "common.incomes"): Color.income,
                    String(localized: "common.expenses"): Color.expense
                ])
                .frame(height: 220)
            }
        }
        .akifiCard()
    }
}
