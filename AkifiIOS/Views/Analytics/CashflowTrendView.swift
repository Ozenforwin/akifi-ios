import SwiftUI
import Charts

struct CashflowTrendView: View {
    @Environment(AppViewModel.self) private var appViewModel

    let transactions: [Transaction]

    @State private var selectedLabel: String?

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

    private var selectedPoint: TrendPoint? {
        guard let selectedLabel else { return nil }
        return trendData.first { $0.label == selectedLabel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тренд доходов и расходов")
                .font(.headline)

            if trendData.allSatisfy({ $0.income == 0 && $0.expense == 0 }) {
                ContentUnavailableView("Нет данных", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 180)
            } else {
                // Tooltip above chart
                if let selected = selectedPoint {
                    tooltipView(point: selected)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: selectedLabel)
                }

                trendChart
                    .frame(height: 200)

                // Legend
                HStack(spacing: 20) {
                    Spacer()
                    legendItem(color: Color.income, label: "Доход")
                    legendItem(color: Color.expense, label: "Расход")
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    private var trendChart: some View {
        Chart {
            ForEach(trendData) { point in
                incomeMarks(point: point)
                expenseMarks(point: point)
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("Месяц", selected.label))
                    .foregroundStyle(Color.gray.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let plotOrigin = geo[proxy.plotFrame!].origin
                        let x = location.x - plotOrigin.x
                        if let label: String = proxy.value(atX: x) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selectedLabel = selectedLabel == label ? nil : label
                            }
                        }
                    }
            }
        }
    }

    private func incomeMarks(point: TrendPoint) -> some ChartContent {
        LineMark(
            x: .value("Месяц", point.label),
            y: .value("Сумма", point.income),
            series: .value("Тип", "Доходы")
        )
        .foregroundStyle(Color.income)
        .symbol(.circle)
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 2.5))
    }

    private func expenseMarks(point: TrendPoint) -> some ChartContent {
        LineMark(
            x: .value("Месяц", point.label),
            y: .value("Сумма", point.expense),
            series: .value("Тип", "Расходы")
        )
        .foregroundStyle(Color.expense)
        .symbol(.circle)
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 2.5))
    }

    private func tooltipView(point: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text("+\(appViewModel.currencyManager.formatAmount(point.income))")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.income)

            Text("-\(appViewModel.currencyManager.formatAmount(point.expense))")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.expense)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let income: Decimal
    let expense: Decimal
}
