import SwiftUI
import Charts

struct CashflowChartView: View {
    let data: [CashflowPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Денежный поток")
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("Нет данных", systemImage: "chart.bar")
                    .frame(height: 200)
            } else {
                Chart(data) { point in
                    BarMark(
                        x: .value("Период", point.label),
                        y: .value("Сумма", point.income)
                    )
                    .foregroundStyle(.green.gradient)
                    .position(by: .value("Тип", "Доходы"))

                    BarMark(
                        x: .value("Период", point.label),
                        y: .value("Сумма", point.expense)
                    )
                    .foregroundStyle(.red.gradient)
                    .position(by: .value("Тип", "Расходы"))
                }
                .chartForegroundStyleScale([
                    "Доходы": Color.green,
                    "Расходы": Color.red
                ])
                .frame(height: 220)
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
