import SwiftUI
import Charts

struct CashflowChartView: View {
    let data: [CashflowPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "analytics.cashflow"))
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView(String(localized: "common.noData"), systemImage: "chart.bar")
                    .frame(height: 200)
            } else {
                Chart(data) { point in
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
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
