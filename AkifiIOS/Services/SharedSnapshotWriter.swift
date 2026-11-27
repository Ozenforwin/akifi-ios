import Foundation
import WidgetKit

/// Bridge between the main app's `DataStore` and the widget extension's
/// App Group snapshot.
///
/// Computes a lightweight summary (balance / daily limit / streak / today
/// income+expense+net / per-account balances / «Повторить» items) on the
/// main actor, serializes it into the shared container, and asks WidgetKit
/// to reload the widgets whose data changed.
///
/// Called from the data store's debounced `writeWidgetSnapshot()` (every
/// load and mutation, the Home eye toggle), its background flush, and
/// `BudgetMetricsStore` when server budget numbers arrive.
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
        let previous = SharedSnapshotStore.load()
        do {
            try SharedSnapshotStore.save(snapshot)
            // Only the kinds whose slice moved: a budget refresh must not
            // spend the account widgets' reload budget, and an unchanged
            // write (a refresh that brought nothing new) reloads nothing.
            for kind in kindsToReload(from: previous, to: snapshot).sorted() {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        } catch {
            AppLogger.data.warning("SharedSnapshot save failed: \(error.localizedDescription)")
        }
        // Every DataStore load / mutation ends here, so this is where budget
        // metrics learn that the data moved. No-op when nothing changed;
        // when the server answers, the store writes the snapshot again.
        BudgetMetricsStore.shared.refreshIfNeeded(dataStore: dataStore)
    }

    // MARK: - Build

    /// Internal (not private) so tests can check what the widget gets.
    /// `now` and `hiddenBalanceIds` are seams for tests; production reads
    /// the clock and the Home card's eye toggles.
    static func buildSnapshot(
        dataStore: DataStore,
        currencyManager: CurrencyManager,
        now: Date = Date(),
        hiddenBalanceIds: Set<String>? = nil
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
        // Currency lookup over every account (a write-off on a debt account is
        // real spending); the balance total above reads money accounts only.
        let accountCurrencyById: [String: String] = Dictionary(
            dataStore.allAccounts.map { ($0.id, $0.currency) },
            uniquingKeysWith: { first, _ in first }
        )
        // `now` is the parameter (tests pin the day and the month).
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

        // ── «Счёт» widget (v2) ──
        let monthKey = DataStore.monthKey(for: now, calendar: SharedSnapshot.dayCalendar)
        snapshot.monthKey = monthKey
        snapshot.accounts = accountItems(
            dataStore: dataStore,
            monthKey: monthKey,
            hiddenIds: hiddenBalanceIds ?? HiddenBalances.ids()
        )
        // ── «Быстрая запись» widget (v2) ──
        snapshot.repeatItems = repeatItems(dataStore: dataStore, currencyManager: currencyManager)
        return snapshot
    }

    // MARK: - Accounts

    /// One item per MONEY account (`dataStore.accounts`: a «Долги» account
    /// is a person, not money — contract §A7), in the carousel's order, a
    /// duplicate id (a shared account delivered twice) once. Amounts stay in
    /// the account's own currency (ADR-001): the balance is the app's
    /// `nativeBalance(for:)`, the month flow the native twin of the
    /// carousel's month chips.
    static func accountItems(
        dataStore: DataStore,
        monthKey: String,
        hiddenIds: Set<String>
    ) -> [SharedSnapshot.AccountItem] {
        let flows = NativeBalance.monthFlows(monthKey: monthKey, transactions: dataStore.transactions)
        let userId = dataStore.profile?.id
        var seen: Set<String> = []
        var items: [SharedSnapshot.AccountItem] = []
        for account in dataStore.accounts where seen.insert(account.id).inserted {
            let code = account.currency.uppercased()
            let currency = Currency(code: code) ?? Currency(unchecked: code)
            let flow = flows[account.id]
            items.append(SharedSnapshot.AccountItem(
                id: account.id,
                name: account.name,
                icon: account.icon,
                colorHex: account.color,
                currencyCode: currency.code,
                currencySymbol: currency.symbol,
                currencyDecimals: currency.decimals,
                balance: dataStore.nativeBalance(for: account),
                monthIncome: flow?.income ?? 0,
                monthExpense: flow?.expense ?? 0,
                isPrimary: account.isPrimary,
                isShared: AccountSharingIndex.isShared(account, dataStore: dataStore, currentUserId: userId),
                isBalanceHidden: hiddenIds.contains(account.id)
            ))
        }
        return items
    }

    // MARK: - «Повторить»

    /// How many «Повторить» items the medium widget shows.
    static let repeatItemLimit = 3
    /// Newest own income / expense rows the ranking looks at. The items are
    /// the most recent distinct entries (`QuickEntryPredictor`), so a window
    /// gives the same answer as the whole history while keeping a snapshot
    /// write cheap with years of rows (the text keys are built per row).
    static let repeatHistoryWindow = 400

    /// The top `repeatItemLimit` candidates of the quick-entry sheet's
    /// «Повторить» strip, as display data + the link that opens the sheet
    /// prefilled with each (the sheet saves, the widget never does).
    static func repeatItems(dataStore: DataStore, currencyManager: CurrencyManager) -> [SharedSnapshot.RepeatItem] {
        let userId = dataStore.profile?.id
        let rows = dataStore.transactions
            .filter { !$0.isTransfer && ($0.type == .expense || $0.type == .income) && (userId == nil || $0.userId == userId) }
            .sorted { a, b in
                let da = String(a.rawDateTime.prefix(19)), db = String(b.rawDateTime.prefix(19))
                if da != db { return da > db }
                return (a.createdAt ?? "") > (b.createdAt ?? "")
            }
            .prefix(repeatHistoryWindow)
        let context = QuickEntryContext(
            accounts: dataStore.accounts,
            categories: dataStore.categories,
            displayCategories: dataStore.displayCategories,
            transactions: Array(rows),
            currentUserId: userId,
            fallbackCurrency: currencyManager.dataCurrency.code
        )
        return QuickEntryPredictor.repeatCandidates(context: context, type: nil, limit: repeatItemLimit)
            .map { repeatItem($0, context: context) }
    }

    static func repeatItem(_ item: QuickEntryRepeatItem, context: QuickEntryContext) -> SharedSnapshot.RepeatItem {
        let category = context.displayCategory(item.categoryId)
        let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            if !description.isEmpty { return description }
            if let category { return category.name }
            return item.type == .income ? String(localized: "common.income") : String(localized: "common.expense")
        }()
        let isForeign = item.currencyCode.uppercased() != item.accountCurrency.uppercased()
        let link = QuickEntryLaunchLink(
            mode: item.type == .income ? .income : .expense,
            source: .widget,
            amount: item.amount,
            currency: isForeign ? item.currencyCode : nil,
            categoryId: item.categoryId,
            accountId: item.accountId,
            note: description.isEmpty ? nil : description
        )
        let currency = Currency(code: item.currencyCode) ?? Currency(unchecked: item.currencyCode)
        return SharedSnapshot.RepeatItem(
            id: item.id,
            isIncome: item.type == .income,
            title: title,
            icon: category?.icon,
            amountText: TransactionFormView.formatRawAmount(item.amount, currency: currency),
            accountName: context.account(item.accountId)?.name,
            url: link.url.absoluteString
        )
    }

    // MARK: - Reloads

    /// The widget kinds whose slice of the snapshot differs between `old`
    /// (what the widgets last read) and `new`. No previous snapshot or a
    /// layout change → every kind. `lastUpdated` alone never reloads.
    nonisolated static func kindsToReload(from old: SharedSnapshot?, to new: SharedSnapshot) -> Set<String> {
        guard let old, old.schemaVersion == new.schemaVersion else { return AkifiWidgetKind.all }
        var kinds: Set<String> = []
        let currencyChanged = old.baseCurrency != new.baseCurrency
            || old.baseCurrencySymbol != new.baseCurrencySymbol
            || old.baseCurrencyDecimals != new.baseCurrencyDecimals
        if currencyChanged || old.totalBalance != new.totalBalance || old.accountCount != new.accountCount {
            kinds.insert(AkifiWidgetKind.balance)
        }
        if currencyChanged || old.dailyLimit != new.dailyLimit || old.dailyLimitBudgetName != new.dailyLimitBudgetName
            || old.dailySpentToday != new.dailySpentToday || old.dailyLimitUtilization != new.dailyLimitUtilization
            || old.dailyLimitLeftover != new.dailyLimitLeftover || old.dailyLimitPeriodEnd != new.dailyLimitPeriodEnd
            || old.dayKey != new.dayKey {
            kinds.insert(AkifiWidgetKind.dailyLimit)
        }
        if old.currentStreak != new.currentStreak || old.nextMilestone != new.nextMilestone {
            kinds.insert(AkifiWidgetKind.streak)
        }
        if currencyChanged || old.todayIncome != new.todayIncome || old.todayExpense != new.todayExpense
            || old.todayNet != new.todayNet || old.dayKey != new.dayKey {
            kinds.insert(AkifiWidgetKind.daySummary)
        }
        if old.accounts != new.accounts || old.monthKey != new.monthKey {
            kinds.insert(AkifiWidgetKind.account)
        }
        if old.repeatItems != new.repeatItems {
            kinds.insert(AkifiWidgetKind.quickAdd)
        }
        // «Все счета» lists balances and the base-currency total; the month
        // in / out it doesn't show never reloads it.
        if currencyChanged || old.totalBalance != new.totalBalance
            || listedAccounts(old.accounts) != listedAccounts(new.accounts) {
            kinds.insert(AkifiWidgetKind.accounts)
        }
        return kinds
    }

    /// The accounts as «Все счета» shows them: everything but the month
    /// flow (a field added to `AccountItem` later counts by default).
    nonisolated private static func listedAccounts(_ accounts: [SharedSnapshot.AccountItem]?) -> [SharedSnapshot.AccountItem]? {
        accounts?.map { item in
            var item = item
            item.monthIncome = 0
            item.monthExpense = 0
            return item
        }
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
