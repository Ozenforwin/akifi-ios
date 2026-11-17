import Foundation
import SwiftUI

/// Result of the category donut for one (period, type): the rows the sheet
/// drills into plus the per-category totals in base currency.
struct CategoryBreakdown {
    /// Period-scoped rows of every type (the drill-down sheet filters them).
    let filtered: [Transaction]
    /// Sorted by amount, largest first.
    let spending: [CategorySpending]
    /// Σ `spending.amount` — already FX-normalized.
    let total: Decimal

    static let empty = CategoryBreakdown(filtered: [], spending: [], total: 0)
}

/// View-state for `AnalyticsTabView`: the period / account filters and every
/// derivation the panels draw from.
///
/// Memoization contract (P1): each derivation is computed at most once per
/// distinct key and every panel reads it once per `body`. Keys are built from
/// `DataStore.derivationRevision` — `txGenerationToken` (bumped by
/// `rebuildCaches()`, which also runs on every FX-rate / base-currency
/// change, so it doubles as the FX revision) plus the identity of the
/// `transactions` / `accounts` arrays — and the inputs the derivation reads
/// (filters, categories, subscriptions, the current day). No key hashes the
/// rate table.
///
/// Demo mode (no transactions yet) feeds `DemoData` through the same
/// derivations, keyed like real data, so the panels need no second code path.
///
/// The store is bound from `AnalyticsTabView.body` (Environment is not
/// readable in `init`), so the state exists from the first frame — the old
/// optional state built in `.task` made every panel compute twice on first
/// open: once with fallback inputs, once after the state arrived.
@Observable @MainActor
final class AnalyticsTabState {
    var selectedPeriod: WidgetPeriod = .month
    var selectedAccountId: String?

    @ObservationIgnored private(set) weak var dataStore: DataStore?

    init(dataStore: DataStore? = nil) {
        self.dataStore = dataStore
    }

    /// Attaches the store (idempotent; cheap enough to call from `body`).
    @discardableResult
    func bind(_ store: DataStore) -> AnalyticsTabState {
        if dataStore !== store {
            dataStore = store
            removeAllMemos()
        }
        return self
    }

    // MARK: - Keys

    private struct ScopeKey: Equatable {
        let revision: DerivationRevision
        let accountId: String?
    }

    private struct PeriodKey: Equatable {
        let scope: ScopeKey
        let period: WidgetPeriod
        let threshold: DayKey.Threshold
    }

    private struct AggregatesKey: Equatable {
        let scope: ScopeKey
        let months: Int
        let utcMonth: String
    }

    private struct BreakdownKey: Equatable {
        let period: PeriodKey
        let type: CategoryType
        let categories: ArrayIdentity<Category>
    }

    private struct ForecastKey: Equatable {
        let revision: DerivationRevision
        let subscriptions: ArrayIdentity<SubscriptionTracker>
        let horizonMonths: Int
        let day: String
    }

    @ObservationIgnored private let scopedMemo = Memo<ScopeKey, [Transaction]>()
    @ObservationIgnored private let periodMemo = Memo<PeriodKey, [Transaction]>()
    @ObservationIgnored private let aggregatesMemo = Memo<AggregatesKey, [MonthlyAggregate]>()
    @ObservationIgnored private let cashflowMemo = Memo<PeriodKey, [CashflowPoint]>(capacity: 2)
    @ObservationIgnored private let breakdownMemo = Memo<BreakdownKey, CategoryBreakdown>(capacity: 2)
    @ObservationIgnored private let forecastMemo = Memo<ForecastKey, CashFlowEngine.Forecast>(capacity: 3)

    private func removeAllMemos() {
        scopedMemo.removeAll()
        periodMemo.removeAll()
        aggregatesMemo.removeAll()
        cashflowMemo.removeAll()
        breakdownMemo.removeAll()
        forecastMemo.removeAll()
    }

    /// How many times each derivation actually ran — for tests.
    var computeCounts: [String: Int] {
        [
            "scoped": scopedMemo.computeCount,
            "period": periodMemo.computeCount,
            "aggregates": aggregatesMemo.computeCount,
            "cashflow": cashflowMemo.computeCount,
            "breakdown": breakdownMemo.computeCount,
            "forecast": forecastMemo.computeCount,
        ]
    }

    // MARK: - Projections

    /// True while the user has no real transactions — panels show `DemoData`.
    var isDemo: Bool { dataStore?.transactions.isEmpty ?? true }

    private func scopeKey(_ store: DataStore) -> ScopeKey {
        ScopeKey(revision: store.derivationRevision, accountId: selectedAccountId)
    }

    private func periodKey(_ store: DataStore) -> PeriodKey {
        PeriodKey(
            scope: scopeKey(store),
            period: selectedPeriod,
            threshold: DayKey.Threshold(since: selectedPeriod.startDate())
        )
    }

    /// Transactions filtered by `selectedAccountId` (no period filter); the
    /// full set when no account is selected. `DemoData` in demo mode.
    var scopedTransactions: [Transaction] {
        guard let store = dataStore else { return [] }
        let key = scopeKey(store)
        return scopedMemo.value(for: key) {
            if store.transactions.isEmpty { return DemoData.transactions }
            guard let accountId = key.accountId else { return store.transactions }
            return store.transactions.filter { $0.accountId == accountId }
        }
    }

    /// `scopedTransactions` clipped to `selectedPeriod`.
    var periodTransactions: [Transaction] {
        guard let store = dataStore else { return [] }
        let key = periodKey(store)
        return periodMemo.value(for: key) {
            let threshold = key.threshold
            return scopedTransactions.filter { threshold.admits($0.date) }
        }
    }

    /// Last `months` monthly aggregates (oldest first) for the summary and
    /// trend panels; empty in demo mode (both panels handle that).
    func monthlyAggregates(months: Int = 6) -> [MonthlyAggregate] {
        guard let store = dataStore, !store.transactions.isEmpty else { return [] }
        let key = AggregatesKey(
            scope: scopeKey(store),
            months: months,
            utcMonth: DayKey.month(Date(), timeZone: TimeZone(identifier: "UTC") ?? .current)
        )
        return aggregatesMemo.value(for: key) {
            store.recentMonthlyAggregates(months: months, accountId: key.scope.accountId)
        }
    }

    /// Cashflow bars for the selected period, bucketed to match it (days for
    /// a day/week, weeks for a month, months beyond) — the picker used to
    /// leave the bucketing stuck on "month".
    var cashflowPoints: [CashflowPoint] {
        guard let store = dataStore else { return [] }
        let key = periodKey(store)
        return cashflowMemo.value(for: key) {
            AnalyticsViewModel.cashflowData(
                from: periodTransactions,
                period: AnalyticsPeriod(key.period),
                dataStore: store
            )
        }
    }

    /// Category donut + list for the selected period and `type`.
    func categoryBreakdown(type: CategoryType) -> CategoryBreakdown {
        guard let store = dataStore else { return .empty }
        let categories = store.transactions.isEmpty ? DemoData.categories : store.categories
        let key = BreakdownKey(period: periodKey(store), type: type, categories: ArrayIdentity(categories))
        return breakdownMemo.value(for: key) {
            let filtered = periodTransactions
            let spending = AnalyticsDerivations.categorySpending(
                filtered,
                type: type,
                categories: categories,
                amount: { store.amountInBaseDisplay($0) }
            )
            let total = spending.reduce(Decimal(0)) { $0 + $1.amount } // allowlisted-amount: CategorySpending.amount is already FX-normalized via amountInBaseDisplay
            return CategoryBreakdown(filtered: filtered, spending: spending, total: total)
        }
    }

    /// Cash-flow forecast over `horizonMonths`. Real data only.
    func forecast(horizonMonths: Int) -> CashFlowEngine.Forecast {
        guard let store = dataStore else {
            return CashFlowEngine.forecast(startingBalance: 0, transactions: [], subscriptions: [], monthsAhead: horizonMonths)
        }
        let key = ForecastKey(
            revision: store.derivationRevision,
            subscriptions: ArrayIdentity(store.subscriptions),
            horizonMonths: horizonMonths,
            day: DayKey.day(Date())
        )
        return forecastMemo.value(for: key) {
            let ctx = store.currencyContext
            return CashFlowEngine.forecast(
                startingBalance: Self.startingBalance(store),
                transactions: store.transactions,
                subscriptions: store.subscriptions,
                monthsAhead: horizonMonths,
                accountsById: ctx.accountsById,
                fxRates: ctx.fxRates,
                baseCode: ctx.baseCode
            )
        }
    }

    /// Σ cached account balances (base currency) — the forecast's "today".
    static func startingBalance(_ store: DataStore) -> Int64 {
        store.accounts.reduce(Int64(0)) { $0 + store.balance(for: $1) }
    }
}

/// Pure analytics derivations (unit-tested without SwiftUI).
enum AnalyticsDerivations {
    /// Per-category totals of the non-transfer rows of `type`, largest
    /// first (ties by category id, so the order is stable across recomputes).
    static func categorySpending(
        _ transactions: [Transaction],
        type: CategoryType,
        categories: [Category],
        amount: (Transaction) -> Decimal
    ) -> [CategorySpending] {
        var total: Decimal = 0
        var byCategory: [String: Decimal] = [:]
        for tx in transactions where !tx.isTransfer {
            switch (type, tx.type) {
            case (.expense, .expense), (.income, .income): break
            default: continue
            }
            // ADR-001: per-category totals and the grand total are summed
            // from the same FX-normalized value.
            let value = amount(tx)
            total += value
            byCategory[tx.categoryId ?? "uncategorized", default: 0] += value
        }
        guard total > 0 else { return [] }

        let categoryById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return byCategory.map { catId, value in
            let cat = categoryById[catId]
            return CategorySpending(
                id: catId,
                name: cat?.name ?? String(localized: "common.other"),
                icon: cat?.icon ?? "💰",
                color: cat?.color ?? "#94A3B8",
                amount: value,
                percentage: Double(truncating: (value / total * 100) as NSDecimalNumber)
            )
        }
        .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.id < $1.id }
    }
}
