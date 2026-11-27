import SwiftUI

struct DailyLimitWidgetView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }
    private var metricsStore: BudgetMetricsStore { .shared }

    /// The most restrictive daily allowance across budgets, in the BASE
    /// currency: every budget's allowance is converted before the minimum is
    /// taken (M6 — a $15.90/day budget must not win as «15,90 ₽»). Uses the
    /// same memoized per-budget metrics as the Budgets tab and the widget
    /// (server numbers when available), so the three can't disagree and
    /// nothing is recomputed per render (P5).
    private var safeToSpend: Decimal {
        let resolved = metricsStore.resolved(for: dataStore)
        let items = dataStore.budgets.compactMap { budget in
            resolved[budget.id].map { (budget: budget, metrics: $0.metrics) }
        }
        return BudgetMath.minDailySafeToSpend(items, currencyContext: dataStore.currencyContext)
    }

    var body: some View {
        let value = safeToSpend
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "analytics.availableToday"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(appViewModel.currencyManager.formatAmount(value))
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? Color.primary : Color.expense)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(String(localized: "analytics.recommendedDailyLimit"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .akifiCard()
        .accessibilityElement(children: .combine)
        .task { metricsStore.refreshIfNeeded(dataStore: dataStore) }
    }
}
