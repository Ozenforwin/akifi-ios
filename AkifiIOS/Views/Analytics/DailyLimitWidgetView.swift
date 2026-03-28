import SwiftUI

struct DailyLimitWidgetView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    private var safeToSpend: Decimal {
        let budgets = dataStore.budgets
        let transactions = dataStore.transactions
        guard !budgets.isEmpty else { return 0 }

        // Calculate safe-to-spend as minimum across all budgets
        // (most restrictive budget determines daily limit)
        var minDaily: Decimal?
        for budget in budgets {
            let metrics = BudgetMath.compute(budget: budget, transactions: transactions)
            guard metrics.remainingDays > 0 else { continue }
            let daily = metrics.remaining.displayAmount / Decimal(metrics.remainingDays)
            if let current = minDaily {
                minDaily = min(current, daily)
            } else {
                minDaily = daily
            }
        }

        return max(0, minDaily ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Доступно на сегодня")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(appViewModel.currencyManager.formatAmount(safeToSpend))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(safeToSpend > 0 ? .primary : .red)

            Text("Рекомендуемый дневной лимит расходов")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            LinearGradient(
                colors: [
                    Color.fabEnd.opacity(0.08),
                    Color(.systemBackground)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
