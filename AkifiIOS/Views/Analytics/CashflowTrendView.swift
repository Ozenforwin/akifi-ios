import SwiftUI
import Charts

struct CashflowTrendView: View {
    @Environment(AppViewModel.self) private var appViewModel

    let transactions: [Transaction]

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "LLL"
        df.locale = Locale(identifier: "ru_RU")
        return df
    }()

    private var trendData: [TrendPoint] {
        let cal = Calendar.current
        let now = Date()
        let labelFmt = Self.monthLabelFormatter

        var points: [TrendPoint] = []

        for offset in stride(from: -5, through: 0, by: 1) {
            guard let monthDate = cal.date(byAdding: .month, value: offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month], from: monthDate)
            let df = Self.dateFormatter

            var income: Decimal = 0
            var expense: Decimal = 0
            for tx in transactions {
                guard !tx.isTransfer else { continue }
                guard let date = df.date(from: tx.date) else { continue }
                let txComps = cal.dateComponents([.year, .month], from: date)
                guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                if tx.type == .income { income += tx.amount.displayAmount }
                else if tx.type == .expense { expense += tx.amount.displayAmount }
            }

            let label = labelFmt.string(from: monthDate).capitalized
            points.append(TrendPoint(label: label, income: income, expense: expense))
        }

        return points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тренд (6 месяцев)")
                .font(.headline)

            if trendData.allSatisfy({ $0.income == 0 && $0.expense == 0 }) {
                ContentUnavailableView("Нет данных", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 180)
            } else {
                Chart {
                    ForEach(trendData) { point in
                        LineMark(
                            x: .value("Месяц", point.label),
                            y: .value("Доходы", point.income)
                        )
                        .foregroundStyle(.green)
                        .symbol(.circle)

                        LineMark(
                            x: .value("Месяц", point.label),
                            y: .value("Расходы", point.expense)
                        )
                        .foregroundStyle(.red)
                        .symbol(.triangle)
                    }
                }
                .chartForegroundStyleScale([
                    "Доходы": Color.green,
                    "Расходы": Color.red
                ])
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let income: Decimal
    let expense: Decimal
}
