import Foundation
import WidgetKit

/// Bridge between the main app's `DataStore` and the widget extension's
/// App Group snapshot.
///
/// Computes a lightweight summary (balance / daily limit / streak / today
/// income+expense+net / net worth) on the main actor, serializes it into
/// the shared container, and asks WidgetKit to reload all timelines.
///
/// Called from:
///   - `DataStore.loadAll()` after the initial full fetch,
///   - `DataStore.addTransaction`, `updateTransaction`, `deleteTransaction`
///     after rebuilding caches.
///
/// Widgets NEVER hit the network directly — this writer is the only path
/// from server state into the widget UI.
@MainActor
enum SharedSnapshotWriter {

    /// Build a snapshot from the current `DataStore` + `CurrencyManager`
    /// state and persist it. Silently logs on failure — a widget can always
    /// fall back to its stale value or placeholder.
    static func write(
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) {
        let snapshot = buildSnapshot(dataStore: dataStore, currencyManager: currencyManager)
        do {
            try SharedSnapshotStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            AppLogger.data.warning("SharedSnapshot save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Build

    private static func buildSnapshot(
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) -> SharedSnapshot {
        let baseCurrency = currencyManager.dataCurrency
        let baseCode = baseCurrency.rawValue
        let symbol = baseCurrency.symbol
        let decimals = baseCurrency.decimals

        // Normalise FX rates to Decimal (same convention as NetWorthCalculator).
        let fxRates: [String: Decimal] = currencyManager.rates
            .mapValues { Decimal($0) }

        // ── Balance ──
        var totalBalance: Int64 = 0
        for account in dataStore.accounts {
            let bal = dataStore.balance(for: account)
            totalBalance += NetWorthCalculator.convert(
                amount: bal,
                from: account.currency,
                to: baseCode,
                rates: fxRates
            )
        }

        // ── Today income / expense / net ──
        let todayStr = Self.todayDateString()
        var todayIncome: Int64 = 0
        var todayExpense: Int64 = 0
        for tx in dataStore.transactions where tx.date == todayStr && !tx.isTransfer {
            // Normalize tx amount from its own currency → base currency.
            let txCcy = tx.currency?.uppercased() ?? baseCode
            let normalized = NetWorthCalculator.convert(
                amount: tx.amount,
                from: txCcy,
                to: baseCode,
                rates: fxRates
            )
            switch tx.type {
            case .income: todayIncome += normalized
            case .expense: todayExpense += normalized
            case .transfer: break
            }
        }
        let todayNet = todayIncome - todayExpense

        // ── Daily limit (primary active budget) ──
        let primaryBudget = selectPrimaryBudget(dataStore.budgets)
        var dailyLimit: Int64? = nil
        var dailyLimitName: String? = nil
        var dailySpentToday: Int64 = 0
        var dailyLimitUtilization = 0
        if let budget = primaryBudget {
            let metrics = BudgetMath.compute(
                budget: budget,
                transactions: dataStore.transactions,
                subscriptions: dataStore.subscriptions
            )
            dailyLimit = metrics.safeToSpendDaily
            dailyLimitName = budget.name
            dailyLimitUtilization = metrics.utilization

            // Spent strictly today within that budget's filter scope.
            dailySpentToday = dataStore.transactions
                .filter { tx in
                    guard tx.type == .expense && !tx.isTransfer else { return false }
                    if let cats = budget.categoryIds, !cats.isEmpty {
                        guard let catId = tx.categoryId, cats.contains(catId) else { return false }
                    }
                    if let accId = budget.accountId {
                        guard tx.accountId == accId else { return false }
                    }
                    return tx.date == todayStr
                }
                .reduce(Int64(0)) { partial, tx in
                    let txCcy = tx.currency?.uppercased() ?? baseCode
                    return partial + NetWorthCalculator.convert(
                        amount: tx.amount, from: txCcy, to: baseCode, rates: fxRates
                    )
                }
        }

        // ── Streak ──
        let streak = StreakTracker.currentStreak(from: dataStore.transactions)
        let nextMilestone = StreakTracker.milestones.first(where: { $0 > streak })
            ?? (StreakTracker.milestones.last ?? 365)

        return SharedSnapshot(
            schemaVersion: SharedSnapshot.currentSchemaVersion,
            lastUpdated: Date(),
            baseCurrency: baseCode,
            baseCurrencySymbol: symbol,
            baseCurrencyDecimals: decimals,
            totalBalance: totalBalance,
            accountCount: dataStore.accounts.count,
            dailyLimit: dailyLimit,
            dailyLimitBudgetName: dailyLimitName,
            dailySpentToday: dailySpentToday,
            dailyLimitUtilization: dailyLimitUtilization,
            currentStreak: streak,
            nextMilestone: nextMilestone,
            todayIncome: todayIncome,
            todayExpense: todayExpense,
            todayNet: todayNet,
            netWorth: nil  // reserved for future widget
        )
    }

    // MARK: - Helpers

    private static func todayDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = .current
        return df.string(from: Date())
    }

    /// Choose a single "primary" budget for the daily-limit widget:
    ///   1. An active monthly overall budget (no category filter), else
    ///   2. Any active budget with the smallest limit (most relevant daily cap),
    ///   3. `nil` if none active.
    private static func selectPrimaryBudget(_ budgets: [Budget]) -> Budget? {
        let active = budgets.filter(\.isActive)
        if let overall = active.first(where: {
            $0.billingPeriod == .monthly &&
            ($0.categoryIds == nil || $0.categoryIds?.isEmpty == true)
        }) {
            return overall
        }
        return active.min(by: { $0.amount < $1.amount })
    }
}
