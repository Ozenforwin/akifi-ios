import SwiftUI
import Charts

/// Top-level FIRE-projection screen. Lives under
/// Settings → Бета-функции → Инвестиции → Финансовая независимость.
///
/// The hero number ("X лет до FIRE") is computed from the user's real
/// savings rate (`SavingsRateCalculator`) and current investable net
/// worth (`NetWorthCalculator`). The slider rescales the monthly
/// contribution between 0% and 100% of net disposable income; the
/// toggle below it expands the net-worth definition to include
/// illiquid assets.
///
/// When the user has fewer than 2 non-empty months of activity, the
/// hero is replaced with an onboarding prompt — projecting FIRE
/// from a single month of data is misleading, so we don't.
struct FIREProjectionView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var fireVM = FIREViewModel()
    @State private var nwVM = NetWorthViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                manualOverrideCard
                if fireVM.hasEnoughData {
                    if !fireVM.isManualMode {
                        sliderCard
                    }
                    toggleCard
                    chartCard
                    scenariosCard
                }
                inputsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "fire.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await nwVM.load(dataStore: dataStore, currencyManager: cm)
        if let breakdown = nwVM.breakdown {
            fireVM.load(dataStore: dataStore, currencyManager: cm, breakdown: breakdown)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        if fireVM.hasEnoughData {
            heroComputed
        } else {
            heroInsufficient
        }
    }

    @ViewBuilder
    private var heroComputed: some View {
        let years = fireVM.projection.yearsToFIRE
        let yearsLabel = years.map { formatYears($0) } ?? String(localized: "fire.unreachable")
        let dateLabel: String? = fireVM.projection.fireDate.map {
            AppDateFormatters.displayDate.string(from: $0)
        }

        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "fire.hero.title"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(yearsLabel)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if let dateLabel {
                Text(String(format: String(localized: "fire.hero.dateFormat"), dateLabel))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(String(localized: "fire.hero.4pctRule"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                InfoTooltipButton(
                    titleKey: "fire.tooltip.fourPctRule.title",
                    bodyKey: "fire.tooltip.fourPctRule.body"
                )
            }
            confidencePill
        }
        .akifiCard()
    }

    @ViewBuilder
    private var heroInsufficient: some View {
        ContentUnavailableView {
            Label(String(localized: "fire.insufficient.title"), systemImage: "calendar.badge.clock")
        } description: {
            Text(String(localized: "fire.insufficient.subtitle"))
        }
        .akifiCard()
    }

    private var confidenceLocalizationKey: String {
        switch fireVM.rate.confidence {
        case .low:    return "forecast.confidence.low"
        case .medium: return "forecast.confidence.medium"
        case .high:   return "forecast.confidence.high"
        }
    }

    private var confidenceColor: Color {
        switch fireVM.rate.confidence {
        case .low:    return Color.expense
        case .medium: return Color.warning
        case .high:   return Color.income
        }
    }

    @ViewBuilder
    private var confidencePill: some View {
        HStack(spacing: 6) {
            Circle().fill(confidenceColor).frame(width: 6, height: 6)
            Text(String(localized: String.LocalizationValue(confidenceLocalizationKey)))
                .font(.caption2.weight(.semibold))
            Text(String(format: String(localized: "fire.confidence.monthsFormat"),
                        fireVM.rate.sampleMonths))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Manual override

    @State private var manualExpensesText: String = ""
    @State private var manualContributionText: String = ""
    @State private var didLoadOverrides = false
    /// Briefly flips to true after a successful Apply so the button
    /// can show a checkmark — without this the user has no signal
    /// that the override was accepted (the hero number changes but
    /// far above the fold on long screens).
    @State private var didApply = false
    /// Drives the keyboard dismiss on Apply.
    @FocusState private var manualFieldFocused: ManualField?
    private enum ManualField: Hashable { case expenses, contribution }

    /// Lets the user override the auto-detected monthly expenses and
    /// contribution. Useful with shared accounts: the auto figure
    /// includes "everyone's groceries" but FIRE should be planned
    /// against my-share only. Toggle on → two text fields appear with
    /// auto values pre-filled; "Save" persists them. "Reset" returns
    /// to auto-mode.
    @ViewBuilder
    private var manualOverrideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(String(localized: "fire.manual.title"))
                    .font(.headline)
                InfoTooltipButton(
                    titleKey: "fire.manual.tooltip.title",
                    bodyKey: "fire.manual.tooltip.body"
                )
                Spacer()
                if fireVM.isManualMode {
                    Button(role: .destructive) {
                        fireVM.overrideMonthlyExpenses = nil
                        fireVM.overrideMonthlyContribution = nil
                        loadOverridesFromVM()
                    } label: {
                        Text(String(localized: "fire.manual.reset"))
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 8) {
                manualRow(
                    title: String(localized: "fire.manual.expenses"),
                    placeholder: cm.formatAmount((fireVM.rate.avgMonthlyExpense + fireVM.rate.monthlySubscriptionCost).displayAmount),
                    text: $manualExpensesText,
                    field: .expenses
                )
                manualRow(
                    title: String(localized: "fire.manual.contribution"),
                    placeholder: cm.formatAmount(max(0, fireVM.rate.avgMonthlyNet).displayAmount),
                    text: $manualContributionText,
                    field: .contribution
                )
            }

            HStack {
                Text(fireVM.isManualMode
                     ? String(localized: "fire.manual.statusManual")
                     : String(localized: "fire.manual.statusAuto"))
                    .font(.footnote)
                    .foregroundStyle(fireVM.isManualMode ? Color.income : .secondary)
                Spacer()
                Button {
                    applyManualOverrides()
                } label: {
                    HStack(spacing: 6) {
                        if didApply {
                            Image(systemName: "checkmark")
                                .fontWeight(.bold)
                        }
                        Text(didApply
                             ? String(localized: "fire.manual.applied")
                             : String(localized: "fire.manual.apply"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .animation(.easeInOut(duration: 0.2), value: didApply)
                }
                .buttonStyle(.akifiPrimary)
                .buttonBorderShape(.capsule)
                .tint(didApply ? Color.income : Color.accent)
                .disabled(!hasManualInput)
            }
        }
        .akifiCard()
        .onAppear {
            if !didLoadOverrides {
                didLoadOverrides = true
                loadOverridesFromVM()
            }
        }
    }

    @ViewBuilder
    private func manualRow(title: String, placeholder: String, text: Binding<String>, field: ManualField) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($manualFieldFocused, equals: field)
                .onChange(of: text.wrappedValue) { _, _ in
                    // Any edit invalidates the "Applied!" affordance
                    // — user clearly wants to enter a new value.
                    if didApply { didApply = false }
                }
            Text(cm.dataCurrency.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
        }
    }

    private var hasManualInput: Bool {
        !manualExpensesText.trimmingCharacters(in: .whitespaces).isEmpty
            || !manualContributionText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadOverridesFromVM() {
        manualExpensesText = fireVM.overrideMonthlyExpenses
            .map { decimalText($0) } ?? ""
        manualContributionText = fireVM.overrideMonthlyContribution
            .map { decimalText($0) } ?? ""
    }

    private func applyManualOverrides() {
        let exp = parseKopecks(manualExpensesText)
        let contrib = parseKopecks(manualContributionText)
        fireVM.overrideMonthlyExpenses = manualExpensesText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : exp
        fireVM.overrideMonthlyContribution = manualContributionText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : contrib
        // Visual + tactile confirmation. Without this the user has to
        // scroll up to see the hero number changed — confusing UX.
        manualFieldFocused = nil
        HapticManager.success()
        withAnimation { didApply = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { withAnimation { didApply = false } }
        }
    }

    private func decimalText(_ minor: Int64) -> String {
        let value = Decimal(minor) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.groupingSeparator = ""
        f.decimalSeparator = "."
        return f.string(from: value as NSDecimalNumber) ?? ""
    }

    private func parseKopecks(_ text: String) -> Int64 {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: cleaned) else { return 0 }
        var product = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    // MARK: - Slider

    @ViewBuilder
    private var sliderCard: some View {
        let pct = Int(fireVM.investedFractionOfNet * 100)
        let monthlyAmount = Int64(Double(max(0, fireVM.rate.avgMonthlyNet)) * fireVM.investedFractionOfNet)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "fire.slider.title"))
                    .font(.headline)
                InfoTooltipButton(
                    titleKey: "fire.tooltip.savingsRate.title",
                    bodyKey: "fire.tooltip.savingsRate.body"
                )
                Spacer()
                Text("\(pct)%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.accent)
            }
            Slider(
                value: Binding(
                    get: { fireVM.investedFractionOfNet },
                    set: { fireVM.investedFractionOfNet = $0 }
                ),
                in: 0...1,
                step: 0.05
            )
            HStack {
                Text(String(format: String(localized: "fire.slider.monthlyFormat"),
                            cm.formatAmount(monthlyAmount.displayAmount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: String(localized: "fire.slider.disposableFormat"),
                            cm.formatAmount(max(0, fireVM.rate.avgMonthlyNet).displayAmount)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .akifiCard()
    }

    // MARK: - Toggle

    @ViewBuilder
    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { fireVM.includeIlliquid },
                set: { fireVM.includeIlliquid = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(String(localized: "fire.toggle.includeIlliquid.title"))
                            .font(.subheadline.weight(.semibold))
                        InfoTooltipButton(
                            titleKey: "fire.tooltip.investable.title",
                            bodyKey: "fire.tooltip.investable.body"
                        )
                    }
                    Text(String(localized: "fire.toggle.includeIlliquid.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.accent)
        }
        .akifiCard()
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartCard: some View {
        if let yearsDecimal = fireVM.projection.yearsToFIRE,
           fireVM.projection.fireTarget > 0,
           NSDecimalNumber(decimal: yearsDecimal).doubleValue > 0 {
            chartCardBody(years: yearsDecimal,
                          target: fireVM.projection.fireTarget)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func chartCardBody(years: Decimal, target: Int64) -> some View {
        let yearsDouble = NSDecimalNumber(decimal: years).doubleValue
        let yearsInt = max(1, Int(ceil(yearsDouble)))
        // Use the SAME contribution the projection used. Reading
        // `rate.avgMonthlyNet × slider` here ignored the manual
        // override and left the chart looking flat after Apply.
        let monthlyContrib = fireVM.resolvedMonthlyContribution
        let result = CompoundProjector.project(
            principal: fireVM.netWorth,
            monthlyContribution: monthlyContrib,
            annualReturn: Decimal(string: "0.07")!,
            years: yearsInt
        )
        let targetD = Double(target) / 100.0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "fire.chart.title"))
                    .font(.headline)
                Spacer(minLength: 8)
                // Target label here instead of an in-chart annotation
                // — chart annotations got clipped on the left by the
                // y-axis or on the right by the trailing edge depending
                // on `position`. The card header is roomy and stable.
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.income.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(String(format: String(localized: "fire.chart.targetFormat"),
                                cm.formatAmount(target.displayAmount)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.income)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Chart {
                ForEach(result.points) { point in
                    AreaMark(
                        x: .value("year", point.year),
                        y: .value("value", Double(point.value) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accent.opacity(0.15))
                    LineMark(
                        x: .value("year", point.year),
                        y: .value("value", Double(point.value) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accent)
                }
                RuleMark(y: .value("target", targetD))
                    .foregroundStyle(Color.income.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel().font(.caption2)
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                }
            }
        }
        .akifiCard()
    }

    // MARK: - Scenarios

    @ViewBuilder
    private var scenariosCard: some View {
        if fireVM.projection.scenarios.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "fire.scenarios.title"))
                    .font(.headline)
                Text(String(localized: "fire.scenarios.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(fireVM.projection.scenarios, id: \.percent) { scenario in
                    HStack(spacing: 10) {
                        Text("\(scenario.percent)%")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, alignment: .leading)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Text(scenario.years.map { formatYears($0) } ?? String(localized: "fire.unreachable"))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .akifiCard()
        }
    }

    // MARK: - Inputs read-out

    @ViewBuilder
    private var inputsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "fire.inputs.title"))
                .font(.headline)
            inputsRow(label: String(localized: "fire.inputs.netWorth"),
                      amount: fireVM.netWorth)
            inputsRow(label: String(localized: "fire.inputs.income"),
                      amount: fireVM.rate.avgMonthlyIncome)
            inputsRow(label: String(localized: "fire.inputs.expense"),
                      amount: fireVM.rate.avgMonthlyExpense + fireVM.rate.monthlySubscriptionCost)
            inputsRow(label: String(localized: "fire.inputs.target"),
                      amount: fireVM.projection.fireTarget)
        }
        .akifiCard()
    }

    @ViewBuilder
    private func inputsRow(label: String, amount: Int64) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(cm.formatAmount(amount.displayAmount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: - Helpers

    /// Decimal years → "12.5 лет" / "12.5 years" / "12.5 años".
    /// Matches the rest of Akifi's "round to one fraction digit" style.
    private func formatYears(_ years: Decimal) -> String {
        let pct = NSDecimalNumber(decimal: years).doubleValue
        return String(format: String(localized: "fire.years.format"), pct)
    }
}
