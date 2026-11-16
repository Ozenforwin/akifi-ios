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
        // Every DataStore load / mutation ends here, so this is where budget
        // metrics learn that the data moved. No-op when nothing changed;
        // when the server answers, the store writes the snapshot again.
        BudgetMetricsStore.shared.refreshIfNeeded(dataStore: dataStore)
    }

    // MARK: - Build

    private static func buildSnapshot(
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) -> SharedSnapshot {
        let baseCurrency = currencyManager.dataCurrency
        let baseCode = baseCurrency.code
        let symbol = baseCurrency.symbol
        let decimals = baseCurrency.decimals

        // Normalise FX rates to Decimal (same convention as NetWorthCalculator).
        let fxRates: [String: Decimal] = currencyManager.rates
            .mapValues { Decimal($0) }

        // ── Balance ──
        // `dataStore.balance(for:)` is already in base currency (see
        // DataStore.rebuildCaches). Sum directly — no per-account FX.
        var totalBalance: Int64 = 0
        for account in dataStore.accounts {
            totalBalance += dataStore.balance(for: account)
        }

        // ── Today income / expense / net ──
        // ADR-001: amount is canonical in the account's currency (amountNative).
        // The legacy `tx.currency` label was inconsistent (TMA stored USD
        // labels on RUB values etc.) — using it for FX inflated totals by ~76×
        // on USD-accounts. Source-of-truth is the account.currency now.
        // `uniquingKeysWith`: a shared account can arrive twice (own +
        // member join); `uniqueKeysWithValues` crashed the app on that.
        let accountCurrencyById: [String: String] = Dictionary(
            dataStore.accounts.map { ($0.id, $0.currency) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date()
        let todayStr = SharedSnapshot.dayKey(for: now)
        var todayIncome: Int64 = 0
        var todayExpense: Int64 = 0
        for tx in dataStore.transactions where tx.date == todayStr && !tx.isTransfer {
            let accountCcy = tx.accountId.flatMap { accountCurrencyById[$0] }?.uppercased() ?? baseCode
            let normalized = NetWorthCalculator.convert(
                amount: tx.amountNative,
                from: accountCcy,
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
        // The same metrics the Budgets tab shows (server numbers when
        // available — identical for every member), converted from the
        // budget's currency into the widget's base currency (M6). "Spent
        // today" uses the card's own matching rules — name-matched
        // categories, every linked account, partners' spending (B8).
        let primaryBudget = selectPrimaryBudget(dataStore.budgets)
        var dailyLimit: Int64? = nil
        var dailyLimitName: String? = nil
        var dailySpentToday: Int64 = 0
        var dailyLimitUtilization = 0
        var dailyLimitLeftover: Int64? = nil
        var dailyLimitPeriodEnd: String? = nil
        if let budget = primaryBudget,
           let resolved = BudgetMetricsStore.shared.resolved(for: dataStore, now: now)[budget.id] {
            let ctx = dataStore.currencyContext
            let metrics = resolved.metrics
            dailyLimit = BudgetMath.amountInBase(metrics.safeToSpendDaily, budget: budget, currencyContext: ctx)
            dailyLimitName = budget.name
            dailyLimitUtilization = metrics.utilization
            dailySpentToday = BudgetMath.amountInBase(resolved.spentToday, budget: budget, currencyContext: ctx)
            let leftover = max(0, metrics.effectiveLimit - metrics.spent - metrics.subscriptionCommitted)
            dailyLimitLeftover = BudgetMath.amountInBase(leftover, budget: budget, currencyContext: ctx)
            if metrics.periodEnd != .distantPast {
                dailyLimitPeriodEnd = SharedSnapshot.dayKey(for: metrics.periodEnd)
            }
        }

        // ── Streak ──
        let streak = StreakTracker.currentStreak(from: dataStore.transactions)
        let nextMilestone = StreakTracker.milestones.first(where: { $0 > streak })
            ?? (StreakTracker.milestones.last ?? 365)

        var snapshot = SharedSnapshot(
            schemaVersion: SharedSnapshot.currentSchemaVersion,
            lastUpdated: now,
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
        // Y11: the widget zeroes "today" and re-spreads the allowance when
        // it renders on a later day than this one.
        snapshot.dayKey = todayStr
        snapshot.dailyLimitLeftover = dailyLimitLeftover
        snapshot.dailyLimitPeriodEnd = dailyLimitPeriodEnd
        return snapshot
    }

    // MARK: - Helpers

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
