import SwiftUI
import Charts

struct CashFlowForecastView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var horizon: Horizon = .threeMonths
    @State private var selectedDate: Date?
    @State private var showHowItWorks: Bool = false

    /// The engine is O(N) over transactions; `state.forecast(horizonMonths:)`
    /// memoizes it per (data revision, subscriptions, horizon, day) and the
    /// body reads it once — chart-hover (which only flips `selectedDate`)
    /// never re-runs it, and no key hashes the FX table.
    let state: AnalyticsTabState

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

    private static let axisNumberFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        return nf
    }()

    /// The point whose end-of-month is closest to `selectedDate`, if any.
    private func selectedPoint(in forecast: CashFlowEngine.Forecast) -> CashFlowEngine.MonthPoint? {
        guard let selectedDate else { return nil }
        return forecast.points.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) <
            abs($1.date.timeIntervalSince(selectedDate))
        })
    }

    var body: some View {
        let forecast = state.forecast(horizonMonths: horizon.rawValue)
        VStack(alignment: .leading, spacing: 12) {
            header(forecast)
            horizonPicker
            if forecast.points.isEmpty {
                emptyState
            } else {
                chart(forecast)
                summaryGrid(forecast)
                if let months = forecast.monthsUntilEmpty {
                    runOutAlert(months: months)
                }
                if forecast.confidence == .low {
                    lowConfidenceNote
                }
                howItWorksSection
            }
        }
        .akifiCard()
        .sheet(isPresented: $showHowItWorks) {
            HowItWorksSheet()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Subviews

    /// Title, info button and confidence chip in one row; the chip moves
    /// under the title when the row doesn't fit (long locales, large text)
    /// instead of wrapping the title.
    private func header(_ forecast: CashFlowEngine.Forecast) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                headerTitle
                Spacer(minLength: 8)
                confidenceChip(forecast)
            }
            VStack(alignment: .leading, spacing: 4) {
                headerTitle
                confidenceChip(forecast)
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            Text(String(localized: "forecast.title"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Button {
                showHowItWorks = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "forecast.howItWorks.title")))
        }
    }

    private func confidenceChip(_ forecast: CashFlowEngine.Forecast) -> some View {
        let color = Self.confidenceColor(forecast.confidence)
        return HStack(spacing: 4) {
            Image(systemName: Self.confidenceIcon(forecast.confidence))
                .font(.caption2)
            Text(forecast.confidence.localizedName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .accessibilityLabel(Text("\(forecast.confidence.localizedName), \(forecast.sampleMonths) \(String(localized: "forecast.monthsShort"))"))
    }

    private var horizonPicker: some View {
        Picker(String(localized: "forecast.horizon"), selection: $horizon) {
            ForEach(Horizon.allCases) { h in
                Text(h.localizedName).tag(h)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Base-currency kopecks → display-currency major units, so the plotted
    /// values (and the Y axis derived from them) follow the currency toggle
    /// instead of always showing base-currency magnitudes.
    private func displayY(_ kopecks: Int64) -> Decimal {
        fmt.convert(kopecks.displayAmount)
    }

    @ViewBuilder
    private func chart(_ forecast: CashFlowEngine.Forecast) -> some View {
        let highlighted = selectedPoint(in: forecast)
        // Anchor for "today" (start of day, so it sits just left of the
        // first end-of-month point) and the starting balance, read once.
        let todayAnchor = Calendar.current.startOfDay(for: Date())
        let startY = displayY(AnalyticsTabState.startingBalance(dataStore))
        Chart {
            // Zero baseline (semantic, not the starting balance)
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

            // Starting ("today") anchor — point + label + bridge to first projected point
            PointMark(
                x: .value("date", todayAnchor),
                y: .value("balance", startY)
            )
            .foregroundStyle(Color.accent)
            .symbolSize(80)
            .symbol(.circle)
            .annotation(position: .top, alignment: .leading, spacing: 4) {
                Text(String(localized: "forecast.now"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // Bridge: today → first projected month, drawn solid so the eye
            // follows the curve from the starting balance.
            if let first = forecast.points.first {
                LineMark(
                    x: .value("date", todayAnchor),
                    y: .value("balance", startY),
                    series: .value("series", "projection")
                )
                .foregroundStyle(Color.accent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))

                LineMark(
                    x: .value("date", first.date),
                    y: .value("balance", displayY(first.projectedBalance)),
                    series: .value("series", "projection")
                )
                .foregroundStyle(Color.accent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }

            // Confidence band
            ForEach(forecast.points, id: \.date) { point in
                AreaMark(
                    x: .value("date", point.date),
                    yStart: .value("low", displayY(point.pessimistic)),
                    yEnd: .value("high", displayY(point.optimistic))
                )
                .foregroundStyle(Color.accent.opacity(0.15))
                .interpolationMethod(.catmullRom)
            }

            // Projected line (continuation from the bridge above)
            ForEach(forecast.points, id: \.date) { point in
                LineMark(
                    x: .value("date", point.date),
                    y: .value("balance", displayY(point.projectedBalance)),
                    series: .value("series", "projection")
                )
                .foregroundStyle(Color.accent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [4, 3]))

                PointMark(
                    x: .value("date", point.date),
                    y: .value("balance", displayY(point.projectedBalance))
                )
                .foregroundStyle(point.projectedBalance < 0 ? Color.expense : Color.accent)
                .symbolSize(50)
            }

            // Selection indicator
            if let selected = highlighted {
                RuleMark(x: .value("selected", selected.date))
                    .foregroundStyle(Color.accent.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(forecast.points.count + 1, 6))) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Self.axisNumberFormatter.string(from: NSNumber(value: v)) ?? "0") \(fmt.selectedCurrency.symbol)")
                    }
                }
                AxisGridLine()
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 200)
        .overlay(alignment: .topTrailing) {
            if let selected = highlighted {
                selectionTooltip(for: selected)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: highlighted?.date)
    }

    private func selectionTooltip(for point: CashFlowEngine.MonthPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.date, format: .dateTime.month(.wide).year())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            tooltipRow(
                label: String(localized: "forecast.tooltip.balance"),
                value: fmt.formatAmount(point.projectedBalance.displayAmount),
                color: point.projectedBalance < 0 ? Color.expense : Color.accent
            )
            tooltipRow(
                label: String(localized: "forecast.tooltip.optimistic"),
                value: fmt.formatAmount(point.optimistic.displayAmount),
                color: Color.income
            )
            tooltipRow(
                label: String(localized: "forecast.tooltip.pessimistic"),
                value: fmt.formatAmount(point.pessimistic.displayAmount),
                color: Color.expense
            )
            Divider().padding(.vertical, 2)
            tooltipRow(
                label: String(localized: "forecast.avgIncome"),
                value: fmt.formatAmount(point.expectedIncome.displayAmount),
                color: .secondary
            )
            tooltipRow(
                label: String(localized: "forecast.avgExpense"),
                value: fmt.formatAmount(point.expectedExpense.displayAmount),
                color: .secondary
            )
        }
        .padding(10)
        // Callout inside the card: one step up the grouped palette, no
        // material, no shadow.
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tooltipRow(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    /// Four figures in a row; a 2 × 2 grid when they don't fit (large
    /// Dynamic Type).
    private func summaryGrid(_ forecast: CashFlowEngine.Forecast) -> some View {
        let income = summaryCell(
            label: String(localized: "forecast.avgIncome"),
            value: fmt.formatAmount(forecast.avgMonthlyIncome.displayAmount),
            color: Color.income
        )
        let expense = summaryCell(
            label: String(localized: "forecast.avgExpense"),
            value: fmt.formatAmount(forecast.avgMonthlyExpense.displayAmount),
            color: Color.expense
        )
        let subscriptions = summaryCell(
            label: String(localized: "forecast.subsMonthly"),
            value: fmt.formatAmount(forecast.monthlySubscriptionCost.displayAmount),
            color: Color.budget
        )
        let net = summaryCell(
            label: String(localized: "forecast.netMonthly"),
            value: (forecast.netMonthly >= 0 ? "+" : "−") + fmt.formatAmount(abs(forecast.netMonthly).displayAmount),
            color: forecast.netMonthly >= 0 ? Color.income : Color.expense
        )
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                income
                expense
                subscriptions
                net
            }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    income
                    expense
                }
                GridRow {
                    subscriptions
                    net
                }
            }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func runOutAlert(months: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.expense)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "forecast.runOut.title"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(
                    format: String(localized: "forecast.runOut.detail"),
                    months
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Semantic: the balance is projected to run out.
        .background(Color.expense.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var howItWorksSection: some View {
        Button {
            showHowItWorks = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                Text(String(localized: "forecast.howItWorks.title"))
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "forecast.noData"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(String(localized: "forecast.noData.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private static func confidenceColor(_ confidence: CashFlowEngine.Confidence) -> Color {
        switch confidence {
        case .high: return Color.income
        case .medium: return Color.warning
        case .low: return .secondary
        }
    }

    private static func confidenceIcon(_ confidence: CashFlowEngine.Confidence) -> String {
        switch confidence {
        case .high: return "checkmark.seal.fill"
        case .medium: return "chart.bar.fill"
        case .low: return "hourglass"
        }
    }
}

// MARK: - How It Works Sheet

private struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        icon: "function",
                        title: String(localized: "forecast.howItWorks.method.title"),
                        body: String(localized: "forecast.howItWorks.method.body")
                    )
                    section(
                        icon: "chart.bar.fill",
                        title: String(localized: "forecast.howItWorks.confidence.title"),
                        body: String(localized: "forecast.howItWorks.confidence.body")
                    )
                    section(
                        icon: "waveform.path.ecg",
                        title: String(localized: "forecast.howItWorks.band.title"),
                        body: String(localized: "forecast.howItWorks.band.body")
                    )
                    section(
                        icon: "exclamationmark.triangle",
                        title: String(localized: "forecast.howItWorks.limits.title"),
                        body: String(localized: "forecast.howItWorks.limits.body")
                    )
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "forecast.howItWorks.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
        }
    }

    private func section(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
