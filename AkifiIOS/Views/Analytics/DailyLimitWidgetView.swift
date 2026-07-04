import SwiftUI

struct DailyLimitWidgetView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    // MARK: - Memoization
    //
    // BudgetMath.compute is O(transactions) per budget; running it in a
    // computed property meant every body evaluation paid O(budgets × N).
    // Same .task(id:)-promoted cache pattern as CategoryBreakdownView.

    private struct CacheKey: Equatable {
        let txCount: Int
        let txGeneration: UInt64
        let budgetsFingerprint: Int
        let externalSpendFingerprint: Int
        /// Safe-to-spend divides by remaining days — the value legitimately
        /// changes at midnight even when no data changed. With keep-alive
        /// tabs nothing else would invalidate it overnight.
        let dayKey: String
    }

    @State private var cachedKey: CacheKey?
    @State private var cachedValue: Decimal = 0

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var currentKey: CacheKey {
        var budgetsHasher = Hasher()
        for budget in dataStore.budgets {
            budgetsHasher.combine(budget.id)
            budgetsHasher.combine(budget.amount)
            budgetsHasher.combine(budget.updatedAt)
            budgetsHasher.combine(budget.isActive)
        }
        var spendHasher = Hasher()
        for (budgetId, rows) in dataStore.externalSpendByBudget.sorted(by: { $0.key < $1.key }) {
            spendHasher.combine(budgetId)
            spendHasher.combine(rows.count)
        }
        return CacheKey(
            txCount: dataStore.transactions.count,
            txGeneration: dataStore.txGenerationToken,
            budgetsFingerprint: budgetsHasher.finalize(),
            externalSpendFingerprint: spendHasher.finalize(),
            dayKey: Self.dayFormatter.string(from: Date())
        )
    }

    /// Memoized with a synchronous fallback on miss — the first frame after
    /// an invalidation still shows the correct number, `.task(id:)` then
    /// promotes it into @State so subsequent renders are O(1).
    private var safeToSpend: Decimal {
        if cachedKey == currentKey {
            return cachedValue
        }
        return computeSafeToSpend()
    }

    private func computeSafeToSpend() -> Decimal {
        BudgetMath.minDailySafeToSpend(
            budgets: dataStore.budgets,
            transactions: dataStore.transactions,
            categories: dataStore.categories,
            externalSpendByBudget: dataStore.externalSpendByBudget,
            currencyContext: dataStore.currencyContext
        )
    }

    var body: some View {
        let value = safeToSpend
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "analytics.availableToday"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(appViewModel.currencyManager.formatAmount(value))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(value > 0 ? .primary : .red)

            Text(String(localized: "analytics.recommendedDailyLimit"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: currentKey) {
            cachedValue = computeSafeToSpend()
            cachedKey = currentKey
        }
    }
}
