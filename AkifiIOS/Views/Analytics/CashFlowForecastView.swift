import SwiftUI
import Charts

struct CashFlowForecastView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var horizon: Horizon = .threeMonths

    enum Horizon: Int, CaseIterable, Identifiable {
        case oneMonth = 1, threeMonths = 3, sixMonths = 6
        var id: Int { rawValue }
        var localizedName: String {
            switch self {
            case .oneMonth: return String(localized: "forecast.horizon.1m")
            case .threeMonths: return String(localized: "forecast.horizon.3m")
            case .sixMonths: return String(localized: "forecast.horizon.6m")
            }
        }
    }

    private var dataStore: DataStore { appViewModel.dataStore }
    private var fmt: CurrencyManager { appViewModel.currencyManager }

    private var startingBalance: Int64 {
        dataStore.accounts.reduce(Int64(0)) { $0 + dataStore.balance(for: $1) }
    }

    private var forecast: CashFlowEngine.Forecast {
        CashFlowEngine.forecast(
            startingBalance: startingBalance,
            transactions: dataStore.transactions,
            subscriptions: dataStore.subscriptions,
            monthsAhead: horizon.rawValue
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            horizonPicker
            if forecast.points.isEmpty {
                emptyState
            } else {
                chart
                summaryGrid
                if forecast.confidence == .low {
                    lowConfidenceNote
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(Color.accent)
            Text(String(localized: "forecast.title"))
                .font(.headline)
            Spacer()
            Text(forecast.confidence.localizedName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(confidenceColor.opacity(0.15))
                .foregroundStyle(confidenceColor)
                .clipShape(Capsule())
        }
    }

    private var horizonPicker: some View {
        Picker(String(localized: "forecast.horizon"), selection: $horizon) {
            ForEach(Horizon.allCases) { h in
                Text(h.localizedName).tag(h)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            // Starting balance marker
            RuleMark(y: .value("zero", startingBalance.displayAmount))
                .foregroundStyle(Color.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

            // Confidence band
            ForEach(forecast.points, id: \.date) { point in
                AreaMark(
                    x: .value("date", point.date),
                    yStart: .value("low", point.pessimistic.displayAmount),
                    yEnd: .value("high", point.optimistic.displayAmount)
                )
                .foregroundStyle(Color.accent.opacity(0.15))
                .interpolationMethod(.catmullRom)
            }

            // Projected line
            ForEach(forecast.points, id: \.date) { point in
                LineMark(
                    x: .value("date", point.date),
                    y: .value("balance", point.projectedBalance.displayAmount)
                )
                .foregroundStyle(Color.accent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [4, 3]))

                PointMark(
                    x: .value("date", point.date),
                    y: .value("balance", point.projectedBalance.displayAmount)
                )
                .foregroundStyle(point.projectedBalance < 0 ? Color.expense : Color.accent)
                .symbolSize(50)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(forecast.points.count, 6))) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel()
                AxisGridLine()
            }
        }
        .frame(height: 180)
    }

    private var summaryGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            summaryCell(
                label: String(localized: "forecast.avgIncome"),
                value: fmt.formatAmount(forecast.avgMonthlyIncome.displayAmount),
                color: Color.income
            )
            summaryCell(
                label: String(localized: "forecast.avgExpense"),
                value: fmt.formatAmount(forecast.avgMonthlyExpense.displayAmount),
                color: Color.expense
            )
            summaryCell(
                label: String(localized: "forecast.subsMonthly"),
                value: fmt.formatAmount(forecast.monthlySubscriptionCost.displayAmount),
                color: Color.budget
            )
            summaryCell(
                label: String(localized: "forecast.netMonthly"),
                value: (forecast.netMonthly >= 0 ? "+" : "−") + fmt.formatAmount(abs(forecast.netMonthly).displayAmount),
                color: forecast.netMonthly >= 0 ? Color.income : Color.expense
            )
        }
    }

    private func summaryCell(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lowConfidenceNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "forecast.lowConfidence"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .foregroundStyle(.secondary)
            Text(String(localized: "forecast.noData"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var confidenceColor: Color {
        switch forecast.confidence {
        case .high: return Color.income
        case .medium: return Color.warning
        case .low: return .secondary
        }
    }
}
