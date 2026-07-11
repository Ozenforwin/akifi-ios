import SwiftUI
import Charts

struct CashFlowForecastView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var horizon: Horizon = .threeMonths
    @State private var selectedDate: Date?
    @State private var showHowItWorks: Bool = false

    /// Memoization for `forecast`. The engine is O(N) over transactions and
    /// is invoked from many computed properties used by `body` (chart marks,
    /// summary grid, confidence chip, run-out alert). Without memoization,
    /// every chart-hover (which only flips `selectedDate`) re-triggers a
    /// full forecast pass — visibly janky on accounts with 1000+ tx.
    ///
    /// The cache is keyed on the stable inputs that actually feed
    /// `CashFlowEngine.forecast`. Identity-based keys (object pointers) are
    /// avoided — `DataStore` re-publishes value-type arrays on every sync,
    /// so identity flips even when the data is unchanged.
    @State private var cachedForecast: (key: ForecastCacheKey, value: CashFlowEngine.Forecast)?

    private struct ForecastCacheKey: Equatable, Hashable {
        let transactionsCount: Int
        let subscriptionsCount: Int
        let accountsCount: Int
        let horizonMonths: Int
        let startingBalance: Int64
        let baseCode: String
        let fxRatesFingerprint: Int
    }

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

    private var startingBalance: Int64 {
        dataStore.accounts.reduce(Int64(0)) { $0 + dataStore.balance(for: $1) }
    }

    /// Current cache key derived from the inputs that genuinely feed
    /// `CashFlowEngine.forecast`. Cheap to build (O(N rates) on FX dict —
    /// in practice <30 entries).
    private var forecastCacheKey: ForecastCacheKey {
        let ctx = dataStore.currencyContext
        return ForecastCacheKey(
            transactionsCount: dataStore.transactions.count,
            subscriptionsCount: dataStore.subscriptions.count,
            accountsCount: dataStore.accounts.count,
            horizonMonths: horizon.rawValue,
            startingBalance: startingBalance,
            baseCode: ctx.baseCode,
            fxRatesFingerprint: Self.fingerprint(for: ctx.fxRates)
        )
    }

    /// Returns the cached forecast when inputs match; otherwise computes
    /// inline. The cache is *populated* via `.onChange` / `.task` modifiers
    /// on the view body — never from inside this getter — to avoid the
    /// classic SwiftUI re-render loop ("write @State from body → invalidate
    /// → write @State from body → ...").
    ///
    /// Worst case (stale cache, body re-evaluated): we compute the forecast
    /// inline once, the next runloop tick fires `.onChange`, the cache is
    /// refreshed, and subsequent re-evaluations (chart-hover, animation
    /// ticks) hit the fast path. No engine work on `selectedDate` flips.
    private var forecast: CashFlowEngine.Forecast {
        let key = forecastCacheKey
        if let cached = cachedForecast, cached.key == key {
            return cached.value
        }
        return computeForecast()
    }

    private func computeForecast() -> CashFlowEngine.Forecast {
        let ctx = dataStore.currencyContext
        return CashFlowEngine.forecast(
            startingBalance: startingBalance,
            transactions: dataStore.transactions,
            subscriptions: dataStore.subscriptions,
            monthsAhead: horizon.rawValue,
            accountsById: ctx.accountsById,
            fxRates: ctx.fxRates,
            baseCode: ctx.baseCode
        )
    }

    /// Cheap fingerprint of the FX rates dictionary — count + a hash of
    /// its sorted (code, rate) pairs. Stable regardless of dict ordering.
    private static func fingerprint(for rates: [String: Decimal]) -> Int {
        var hasher = Hasher()
        hasher.combine(rates.count)
        for code in rates.keys.sorted() {
            hasher.combine(code)
            hasher.combine(rates[code])
        }
        return hasher.finalize()
    }

    /// Anchor date for "today" on the chart (start of day, so it visually
    /// sits just to the left of the first end-of-month point).
    private var todayAnchor: Date { Calendar.current.startOfDay(for: Date()) }

    /// The point whose end-of-month is closest to `selectedDate`, if any.
    private var selectedPoint: CashFlowEngine.MonthPoint? {
        guard let selectedDate else { return nil }
        return forecast.points.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) <
            abs($1.date.timeIntervalSince(selectedDate))
        })
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
                if let months = forecast.monthsUntilEmpty {
                    runOutAlert(months: months)
                }
                if forecast.confidence == .low {
                    lowConfidenceNote
                }
                howItWorksSection
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showHowItWorks) {
            HowItWorksSheet()
        }
        .task(id: forecastCacheKey) {
            // Refresh the memo whenever the inputs change. Runs once on
            // appear (when the cache is nil) and again only on real input
            // changes — chart-hover doesn't touch any field of the key, so
            // SwiftUI does not re-fire this task.
            let key = forecastCacheKey
            if cachedForecast?.key != key {
                cachedForecast = (key, computeForecast())
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(Color.accent)
            Text(String(localized: "forecast.title"))
                .font(.headline)

            Button {
                showHowItWorks = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "forecast.howItWorks.title")))

            Spacer()
            confidenceChip
        }
    }

    private var confidenceChip: some View {
        HStack(spacing: 4) {
            Image(systemName: confidenceIcon)
                .font(.caption2)
            Text(forecast.confidence.localizedName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(confidenceColor.opacity(0.15))
        .foregroundStyle(confidenceColor)
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
    private var chart: some View {
        Chart {
            // Zero baseline (semantic, not the starting balance)
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

            // Starting ("today") anchor — point + label + bridge to first projected point
            PointMark(
                x: .value("date", todayAnchor),
                y: .value("balance", displayY(startingBalance))
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
                    y: .value("balance", displayY(startingBalance)),
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
            if let selected = selectedPoint {
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
            if let selected = selectedPoint {
                selectionTooltip(for: selected)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selectedPoint?.date)
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
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
        .background(Color.expense.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var confidenceColor: Color {
        switch forecast.confidence {
        case .high: return Color.income
        case .medium: return Color.warning
        case .low: return .secondary
        }
    }

    private var confidenceIcon: String {
        switch forecast.confidence {
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
