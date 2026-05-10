import SwiftUI
import Charts

struct CashflowTrendView: View {
    @Environment(AppViewModel.self) private var appViewModel

    /// Pre-aggregated 6 months in base currency (kopecks), oldest first.
    /// `DataStore.recentMonthlyAggregates(months: 6, ...)` zero-fills empty
    /// months so the chart x-axis is always continuous.
    let aggregates: [MonthlyAggregate]

    @State private var selectedLabel: String?

    private static let monthKeyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "LLL"
        df.locale = Locale.current
        return df
    }()

    /// Convert each `MonthlyAggregate` directly into a `TrendPoint`.
    /// Single O(N) pass — N is at most 6 — replaces the previous nested
    /// month × tx loop that called `DateFormatter.date(from:)` per row.
    private var trendData: [TrendPoint] {
        let keyFmt = Self.monthKeyFormatter
        let labelFmt = Self.monthLabelFormatter
        return aggregates.map { agg in
            let label: String
            if let date = keyFmt.date(from: agg.monthKey) {
                label = labelFmt.string(from: date).capitalized
            } else {
                label = agg.monthKey
            }
            return TrendPoint(
                label: label,
                income: Decimal(agg.income) / Decimal(100),
                expense: Decimal(agg.expense) / Decimal(100)
            )
        }
    }

    private var selectedPoint: TrendPoint? {
        guard let selectedLabel else { return nil }
        return trendData.first { $0.label == selectedLabel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "analytics.cashflowTrend"))
                .font(.headline)

            if trendData.allSatisfy({ $0.income == 0 && $0.expense == 0 }) {
                ContentUnavailableView(String(localized: "common.noData"), systemImage: "chart.line.uptrend.xyaxis")
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
                    legendItem(color: Color.income, label: String(localized: "common.income"))
                    legendItem(color: Color.expense, label: String(localized: "common.expense"))
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
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
                RuleMark(x: .value(String(localized: "chart.month"), selected.label))
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
            x: .value(String(localized: "chart.month"), point.label),
            y: .value(String(localized: "chart.amount"), point.income),
            series: .value("type", String(localized: "common.incomes"))
        )
        .foregroundStyle(Color.income)
        .symbol(.circle)
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 2.5))
    }

    private func expenseMarks(point: TrendPoint) -> some ChartContent {
        LineMark(
            x: .value(String(localized: "chart.month"), point.label),
            y: .value(String(localized: "chart.amount"), point.expense),
            series: .value("type", String(localized: "common.expenses"))
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
