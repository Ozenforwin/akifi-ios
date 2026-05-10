import Foundation
import os

/// Aggregated income / expense for a single yyyy-MM bucket, in the user's
/// **base currency** (kopecks). Built once per `rebuildCaches()` and read
/// by analytics widgets via `DataStore.recentMonthlyAggregates(...)`.
///
/// Contract: net cashflow only. Transactions of type `.transfer` (or any row
/// carrying a `transferGroupId`) are excluded — they move money between the
/// user's own accounts and would double-count or cancel out depending on
/// account scope.
struct MonthlyAggregate: Sendable, Equatable {
    let monthKey: String       // "yyyy-MM"
    let income: Int64          // base currency, kopecks
    let expense: Int64         // base currency, kopecks
    var net: Int64 { income - expense }
}

@Observable @MainActor
final class DataStore {
    var accounts: [Account] = []
    var transactions: [Transaction] = []
    var categories: [Category] = []
    var isLoading = false
    var error: String?

    /// Optional back-reference to `CurrencyManager` — injected by
    /// `AppViewModel` so that `rebuildCaches()` can refresh the widget
    /// snapshot with correct FX rates.
    var currencyManager: CurrencyManager?

    /// A recently-auto-matched subscription payment, surfaced as a banner in the UI.
    /// When non-nil, the root view shows an undo-banner; it auto-dismisses after 5 s.
    var pendingAutoMatch: PendingAutoMatch?

    private var balanceCache: [String: Int64] = [:]
    private var categoryIndex: [String: Category] = [:]
    // Pre-computed per-account income/expense for cards
    private(set) var accountIncome: [String: Int64] = [:]
    private(set) var accountExpense: [String: Int64] = [:]

    // MARK: - FX context cache
    //
    // Analytics-heavy screens (cashflow, category breakdown, monthly summary,
    // daily-limit widget) call `amountInBase(_:)` thousands of times per
    // render. Rebuilding `[accountId: Account]` and `[String: Decimal]` on
    // every call was the dominant cost — for ~2 000 transactions and 6
    // analytics passes that's tens of thousands of dictionary allocations.
    //
    // We cache them as `@ObservationIgnored` so mutations don't trigger
    // SwiftUI redraws (the cache is derived state — `accounts` /
    // `currencyManager.rates` are the canonical sources). Keep these in
    // sync via `rebuildCurrencyContext()`.
    @ObservationIgnored private var accountsById: [String: Account] = [:]
    @ObservationIgnored private var fxRatesDecimal: [String: Decimal] = [:]
    @ObservationIgnored private var baseCurrencyCode: String = "RUB"

    // MARK: - Monthly aggregate cache (analytics)
    //
    // Pre-bucketed income/expense per yyyy-MM, in base currency (kopecks).
    // Built eagerly in `rebuildCaches()` because the cost is trivial
    // (O(transactions)) and analytics widgets hit these on every render
    // / period change. Power-users have 5-15 accounts → per-account map
    // stays under a few KB.
    //
    // Excludes `.transfer` rows and anything tagged with `transferGroupId`
    // (cross-leg moves between user's own accounts) so the totals reflect
    // true net cashflow.
    @ObservationIgnored private(set) var monthlyAggregates: [String: MonthlyAggregate] = [:]
    @ObservationIgnored private(set) var monthlyAggregatesByAccount: [String: [String: MonthlyAggregate]] = [:]

    /// Monotonic counter bumped at the end of every `rebuildCaches()` and on
    /// `currencyContextDidChange()`. Downstream `@Observable` view-states
    /// (e.g. `AnalyticsTabState`) compare this token in their cache key —
    /// any change forces re-derivation without needing per-property KVO.
    @ObservationIgnored private(set) var txGenerationToken: UInt64 = 0

    private let accountRepo = AccountRepository()
    private let transactionRepo = TransactionRepository()
    private let categoryRepo = CategoryRepository()
    private let budgetRepo = BudgetRepository()
    private let subscriptionRepo = SubscriptionTrackerRepository()
    private let profileRepo = ProfileRepository()

    var budgets: [Budget] = []
    var subscriptions: [SubscriptionTracker] = []
    var profile: Profile?
    var profilesMap: [String: Profile] = [:]

    private let cache = PersistenceManager.shared
    let offlineQueue = OfflineQueue()

    // MARK: - Auto-match settings key
    static let autoMatchEnabledKey = "subscriptionsAutoMatchEnabled"

    func loadAll() async {
        isLoading = true
        error = nil

        // 1. Load from offline cache first (instant)
        loadFromCache()
        rebuildCaches()

        // 1b. Sync offline queue if we have pending operations
        if offlineQueue.hasPending && NetworkMonitor.shared.isConnected {
            await offlineQueue.processQueue()
        }

        // 2. Fetch fresh data from network
        var errors: [String] = []

        async let accountsFetch = accountRepo.fetchAll()
        async let txFetch = transactionRepo.fetchAll()
        async let catsFetch = categoryRepo.fetchAll()
        async let budgetsFetch = budgetRepo.fetchAll()
        async let subsFetch = subscriptionRepo.fetchAll()
        async let profileFetch = profileRepo.fetch()

        do { accounts = try await accountsFetch }
        catch { AppLogger.data.warning("accounts: \(error)"); errors.append("accounts") }

        do { transactions = try await txFetch }
        catch { AppLogger.data.warning("transactions: \(error)"); errors.append("transactions") }

        do { categories = try await catsFetch }
        catch { AppLogger.data.warning("categories: \(error)"); errors.append("categories") }

        do { budgets = try await budgetsFetch }
        catch { AppLogger.data.warning("budgets: \(error)"); errors.append("budgets") }

        do { subscriptions = try await subsFetch }
        catch { AppLogger.data.warning("subscriptions: \(error)"); errors.append("subscriptions") }

        do { profile = try await profileFetch }
        catch { AppLogger.data.debug("profile: \(error)") }

        // Sequential: depends on transactions & profile being loaded
        do {
            let currentUserId = profile?.id ?? ""
            let otherUserIds = Array(Set(transactions.map(\.userId)).filter { $0 != currentUserId })
            if !otherUserIds.isEmpty {
                let otherProfiles = try await profileRepo.fetchAll(ids: otherUserIds)
                for p in otherProfiles {
                    profilesMap[p.id] = p
                }
            }
            if let profile { profilesMap[profile.id] = profile }
        } catch {
            AppLogger.data.debug("profiles map: \(error)")
        }

        if !errors.isEmpty {
            self.error = errors.joined(separator: "; ")
            AppLogger.data.warning("Load completed with errors: \(self.error!)")
        }

        // 3. Save fresh data to offline cache
        saveToCache()
        rebuildCaches()
        writeWidgetSnapshot()
        isLoading = false
    }

    /// Persist a fresh `SharedSnapshot` for the widget extension and ask
    /// WidgetKit to reload timelines. Safe no-op if `currencyManager`
    /// hasn't been injected yet (tests, cold-start before wiring).
    private func writeWidgetSnapshot() {
        guard let currencyManager else { return }
        SharedSnapshotWriter.write(dataStore: self, currencyManager: currencyManager)
    }

    // MARK: - Offline Cache

    private func loadFromCache() {
        if let cached = cache.loadAccounts(), !cached.isEmpty { accounts = cached }
        if let cached = cache.loadTransactions(), !cached.isEmpty { transactions = cached }
        if let cached = cache.loadCategories(), !cached.isEmpty { categories = cached }
        if let cached = cache.loadBudgets(), !cached.isEmpty { budgets = cached }
        if let cached = cache.loadSubscriptions(), !cached.isEmpty { subscriptions = cached }
        if let cached = cache.loadProfile() { profile = cached }
    }

    private func saveToCache() {
        cache.saveAccounts(accounts)
        cache.saveTransactions(transactions)
        cache.saveCategories(categories)
        cache.saveBudgets(budgets)
        cache.saveSubscriptions(subscriptions)
        if let profile { cache.saveProfile(profile) }
    }

    func addTransaction(_ input: CreateTransactionInput) async throws -> Transaction {
        if !NetworkMonitor.shared.isConnected {
            offlineQueue.enqueue(PendingOperation(operation: .create(input)))
            let placeholder = Transaction(
                id: UUID().uuidString, userId: input.user_id,
                accountId: input.account_id,
                amount: Int64(truncating: (input.amount * 100) as NSDecimalNumber),
                currency: input.currency, description: input.description,
                categoryId: input.category_id, type: TransactionType(rawValue: input.type) ?? .expense,
                date: input.date, merchantName: input.merchant_name,
                merchantFuzzy: nil, transferGroupId: input.transfer_group_id,
                status: "pending", createdAt: nil, updatedAt: nil
            )
            transactions.insert(placeholder, at: 0)
            rebuildCaches()
            writeWidgetSnapshot()
            return placeholder
        }

        let tx = try await transactionRepo.create(input)
        transactions.insert(tx, at: 0)
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logAddTransaction(
            type: input.type,
            amount: Double(truncating: input.amount as NSDecimalNumber),
            category: input.category_id
        )
        await attemptAutoMatch(for: tx)
        return tx
    }

    // MARK: - Subscription auto-match

    /// Structured event surfaced to the UI when a transaction is automatically
    /// linked to a subscription. Contains enough state to undo the operation.
    struct PendingAutoMatch: Identifiable, Equatable {
        let id = UUID()
        let subscriptionId: String
        let subscriptionName: String
        let paymentId: String
        let previousLastPaymentDate: String?
        let previousNextPaymentDate: String?
    }

    /// If auto-match is enabled in Settings, try to link `tx` to an active
    /// subscription. On success, records a payment via the repository and
    /// surfaces a `PendingAutoMatch` so the UI can offer undo.
    ///
    /// Internal so callers like `BankImportView` (which create rows directly
    /// against `TransactionRepository` rather than via `addTransaction`) can
    /// run the same hook on imported rows. Without this, bank-statement
    /// auto-debits would never land in the subscription's payment history.
    func attemptAutoMatch(for tx: Transaction) async {
        // Setting defaults to ON (key missing → use default of true).
        let autoMatchEnabled: Bool = {
            if UserDefaults.standard.object(forKey: Self.autoMatchEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.autoMatchEnabledKey)
        }()
        guard autoMatchEnabled, tx.type == .expense else { return }

        guard let match = SubscriptionMatcher.bestMatch(for: tx, in: subscriptions) else { return }

        let sub = match.subscription
        let previousLast = sub.lastPaymentDate
        let previousNext = sub.nextPaymentDate

        guard let txDate = SubscriptionDateEngine.parseDbDate(tx.date) else { return }

        do {
            let amountDecimal = Decimal(tx.amountNative) / 100
            let paymentDateStr = SubscriptionDateEngine.formatDbDate(txDate)
            let payment = try await subscriptionRepo.addPayment(
                CreateSubscriptionPaymentInput(
                    subscription_id: sub.id,
                    amount: amountDecimal,
                    currency: sub.currency ?? "RUB",
                    payment_date: paymentDateStr
                )
            )
            let newNextDate = SubscriptionDateEngine.nextPaymentDate(from: txDate, period: sub.billingPeriod)
            let newNextStr = SubscriptionDateEngine.formatDbDate(newNextDate)
            try await subscriptionRepo.updateDates(
                id: sub.id,
                lastPaymentDate: paymentDateStr,
                nextPaymentDate: newNextStr
            )

            // Local state update.
            if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                var updated = subscriptions[idx]
                updated.lastPaymentDate = paymentDateStr
                updated.nextPaymentDate = newNextStr
                subscriptions[idx] = updated
                // Reschedule reminder.
                await NotificationManager.scheduleSubscriptionReminder(
                    id: updated.id,
                    serviceName: updated.serviceName,
                    amount: updated.amount,
                    currency: updated.currency ?? "RUB",
                    nextPaymentDate: newNextDate,
                    daysBefore: updated.reminderDays
                )
            }

            pendingAutoMatch = PendingAutoMatch(
                subscriptionId: sub.id,
                subscriptionName: sub.serviceName,
                paymentId: payment.id,
                previousLastPaymentDate: previousLast,
                previousNextPaymentDate: previousNext
            )
            AnalyticsService.logSubscriptionAutoMatch(score: match.score)
        } catch {
            AppLogger.data.warning("Auto-match payment insert failed: \(error.localizedDescription)")
        }
    }

    /// Walk every loaded expense transaction, score it against the given
    /// subscription, and insert a `subscription_payments` row for every
    /// score that clears `SubscriptionMatcher.matchThreshold` and is not
    /// already recorded.
    ///
    /// This is the "Pull from history" affordance — for users whose
    /// subscriptions existed before the auto-match feature shipped, or
    /// who imported a bank statement that pre-dated the integration.
    /// `SubscriptionMatcher.score` already returns 0 for the date
    /// component when the txn is far from `nextPaymentDate`, so historical
    /// rows fall back to amount + merchant scoring (50 + 20 = 70 ≥ 60),
    /// which is the right behavior here — the date axis is meaningless
    /// for older charges.
    ///
    /// After the pass, the subscription's `last_payment_date` and
    /// `next_payment_date` are advanced to follow the most recent matched
    /// txn so reminders line up with reality.
    ///
    /// Returns the number of newly-inserted payments. 0 means either no
    /// matches or every match was already on file.
    @discardableResult
    func backfillPayments(for subscriptionId: String) async -> Int {
        guard let sub = subscriptions.first(where: { $0.id == subscriptionId }) else { return 0 }

        // Pull existing payments so we can dedupe by (subscription, date).
        // Multiple charges on the same day for the same subscription are
        // rare enough that date-only deduping is the pragmatic default; if
        // it ever bites we'd switch to (date, amount) tuple deduping.
        let existing: [SubscriptionPayment]
        do {
            existing = try await subscriptionRepo.fetchPayments(for: subscriptionId)
        } catch {
            AppLogger.data.warning("Backfill: existing-payments fetch failed: \(error.localizedDescription)")
            return 0
        }
        let existingDates = Set(existing.map { String($0.paymentDate.prefix(10)) })

        // Score every loaded expense txn. We don't pre-filter by currency
        // here — the matcher's amount component already requires a currency
        // match before awarding the 50 points, and merchant alone (20 pts)
        // can't clear the 60-point threshold.
        let candidates: [Transaction] = transactions.filter { $0.type == .expense }
        var matches: [Transaction] = []
        for tx in candidates {
            let scored = SubscriptionMatcher.score(transaction: tx, subscription: sub)
            guard scored.total >= SubscriptionMatcher.matchThreshold else { continue }
            let txDayKey = String(tx.date.prefix(10))
            guard !existingDates.contains(txDayKey) else { continue }
            matches.append(tx)
        }

        // Insert in chronological order so the last match wins for the
        // updated `last_payment_date`. SubscriptionDateEngine then derives
        // the next-payment date from the rolling cadence — ready for the
        // reminder scheduler.
        matches.sort { $0.date < $1.date }

        var inserted = 0
        var lastMatchDate: String?
        for tx in matches {
            let amountDecimal = Decimal(tx.amountNative) / 100
            let txDayKey = String(tx.date.prefix(10))
            do {
                _ = try await subscriptionRepo.addPayment(
                    CreateSubscriptionPaymentInput(
                        subscription_id: subscriptionId,
                        amount: amountDecimal,
                        currency: sub.currency ?? tx.currency ?? "RUB",
                        payment_date: txDayKey
                    )
                )
                lastMatchDate = txDayKey
                inserted += 1
            } catch {
                AppLogger.data.warning("Backfill payment insert failed: \(error.localizedDescription)")
            }
        }

        // Roll the subscription's payment dates forward to the most recent
        // matched txn. Skip when nothing matched OR when the existing
        // last_payment_date is already at or past our latest match — we
        // don't want to clobber a future-dated reminder with a stale one.
        if let last = lastMatchDate,
           let lastDate = SubscriptionDateEngine.parseDbDate(last) {
            let shouldAdvance: Bool = {
                guard let currentLast = sub.lastPaymentDate,
                      let currentLastDate = SubscriptionDateEngine.parseDbDate(currentLast)
                else { return true }
                return lastDate > currentLastDate
            }()
            if shouldAdvance {
                let nextDate = SubscriptionDateEngine.nextPaymentDate(from: lastDate, period: sub.billingPeriod)
                let nextStr = SubscriptionDateEngine.formatDbDate(nextDate)
                do {
                    try await subscriptionRepo.updateDates(
                        id: subscriptionId,
                        lastPaymentDate: last,
                        nextPaymentDate: nextStr
                    )
                    if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                        var updated = subscriptions[idx]
                        updated.lastPaymentDate = last
                        updated.nextPaymentDate = nextStr
                        subscriptions[idx] = updated
                        await NotificationManager.scheduleSubscriptionReminder(
                            id: updated.id,
                            serviceName: updated.serviceName,
                            amount: updated.amount,
                            currency: updated.currency ?? "RUB",
                            nextPaymentDate: nextDate,
                            daysBefore: updated.reminderDays
                        )
                    }
                } catch {
                    AppLogger.data.warning("Backfill date update failed: \(error.localizedDescription)")
                }
            }
        }

        return inserted
    }

    /// Revert the most recent auto-match: deletes the payment row, restores
    /// the subscription's prior `last_payment_date` / `next_payment_date`, and
    /// reschedules the reminder accordingly.
    func undoAutoMatch() async {
        guard let match = pendingAutoMatch else { return }
        pendingAutoMatch = nil

        do {
            try await subscriptionRepo.deletePayment(id: match.paymentId)
            try await subscriptionRepo.updateDates(
                id: match.subscriptionId,
                lastPaymentDate: match.previousLastPaymentDate,
                nextPaymentDate: match.previousNextPaymentDate
            )
            if let idx = subscriptions.firstIndex(where: { $0.id == match.subscriptionId }) {
                var sub = subscriptions[idx]
                sub.lastPaymentDate = match.previousLastPaymentDate
                sub.nextPaymentDate = match.previousNextPaymentDate
                subscriptions[idx] = sub

                if sub.status == .active,
                   let nextStr = sub.nextPaymentDate,
                   let nextDate = SubscriptionDateEngine.parseDbDate(nextStr) {
                    await NotificationManager.scheduleSubscriptionReminder(
                        id: sub.id,
                        serviceName: sub.serviceName,
                        amount: sub.amount,
                        currency: sub.currency ?? "RUB",
                        nextPaymentDate: nextDate,
                        daysBefore: sub.reminderDays
                    )
                } else {
                    await NotificationManager.cancelSubscriptionReminder(id: sub.id)
                }
            }
            AnalyticsService.logSubscriptionAutoMatchUndo()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Clears the pending-match banner (used when the user dismisses or the
    /// timer expires, without undoing).
    func clearPendingAutoMatch() {
        pendingAutoMatch = nil
    }

    func updateTransaction(id: String, _ input: UpdateTransactionInput) async throws {
        try await transactionRepo.update(id: id, input)
        // Reload only transactions instead of all data
        do {
            transactions = try await transactionRepo.fetchAll()
            rebuildCaches()
            writeWidgetSnapshot()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteTransaction(_ transaction: Transaction) async {
        do {
            try await transactionRepo.delete(id: transaction.id)
            // If this row was part of an auto-transfer triplet, the RPC
            // deleted ALL three server-side (expense + two transfer legs).
            // Remove the sibling rows from local state too — otherwise the
            // UI would optimistically drop only the swiped row and the other
            // two would "come back" on the next recompute/rerender.
            if let groupId = transaction.autoTransferGroupId {
                transactions.removeAll { $0.autoTransferGroupId == groupId }
            } else {
                transactions.removeAll { $0.id == transaction.id }
            }
            rebuildCaches()
            writeWidgetSnapshot()
            AnalyticsService.logDeleteTransaction()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func category(for transaction: Transaction) -> Category? {
        guard let categoryId = transaction.categoryId else { return nil }
        return categoryIndex[categoryId]
    }

    /// Categories deduplicated by name+type for UI display (pickers, management).
    /// Prefers the current user's own categories over shared-account duplicates.
    var displayCategories: [Category] {
        let currentUserId = profile?.id ?? ""
        // Sort: current user's categories first so they "win" in dedup
        let sorted = categories.sorted { a, b in
            let aOwn = a.userId == currentUserId
            let bOwn = b.userId == currentUserId
            if aOwn != bOwn { return aOwn }
            return (a.createdAt ?? "") < (b.createdAt ?? "")
        }
        var seen: Set<String> = []
        return sorted.filter { cat in
            let key = "\(cat.name.lowercased().trimmingCharacters(in: .whitespaces))_\(cat.type.rawValue)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    func balance(for account: Account) -> Int64 {
        balanceCache[account.id] ?? account.initialBalance
    }

    var recentTransactions: [Transaction] {
        Array(transactions.prefix(10))
    }

    // MARK: - Transaction math helpers

    /// Returns `tx.amountNative` FX-normalized to the user's base currency
    /// (kopecks). Use whenever you aggregate transactions across multiple
    /// accounts — `amountNative` is in each account's own currency and
    /// cannot be summed directly.
    ///
    /// Uses the cached FX context (`accountsById`, `fxRatesDecimal`,
    /// `baseCurrencyCode`) — refreshed via `rebuildCurrencyContext()` on
    /// every data/rate/base-currency change. Hot loops that hit this on
    /// every transaction (analytics, cashflow trend) avoid the per-call
    /// dictionary rebuild that previously dominated render time.
    func amountInBase(_ tx: Transaction) -> Int64 {
        TransactionMath.amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: fxRatesDecimal,
            baseCode: baseCurrencyCode
        )
    }

    /// Decimal variant in main units (not kopecks).
    func amountInBaseDisplay(_ tx: Transaction) -> Decimal {
        Decimal(amountInBase(tx)) / 100
    }

    /// Sums transactions, FX-normalizing each into the user's base
    /// currency. Use this helper in place of `reduce { $0 + $1.amount }`
    /// whenever you aggregate multiple transactions — `amountNative`
    /// alone is not comparable across accounts in different currencies,
    /// and `amount` is the legacy field that produced the VND-as-RUB
    /// bug. `signed: true` negates expenses so totals reflect net flow;
    /// `signed: false` (default) sums absolute contributions.
    func aggregate(_ transactions: [Transaction], signed: Bool = false) -> Int64 {
        transactions.reduce(Int64(0)) { acc, tx in
            let base = amountInBase(tx)
            if signed && tx.type == .expense {
                return acc - base
            }
            return acc + base
        }
    }

    /// Bundled FX context — handy when you need to pass it into a pure
    /// engine (InsightEngine, CashFlowEngine, PDFReportGenerator) that
    /// otherwise has no reference to `DataStore`.
    ///
    /// Returns the cached fields directly — the dictionaries are recomputed
    /// once per data/rate change in `rebuildCurrencyContext()`, not on
    /// every call. Callers that hold the tuple over a hot loop pay zero
    /// per-iteration cost.
    var currencyContext: (accountsById: [String: Account], fxRates: [String: Decimal], baseCode: String) {
        (accountsById, fxRatesDecimal, baseCurrencyCode)
    }

    // MARK: - Assistant Context

    /// Convert internal kopeck value (Int64) to whole currency units (Double).
    private func toUnits(_ kopecks: Int64) -> Double {
        Double(kopecks) / 100.0
    }

    func buildAssistantContext() -> AssistantContext {
        // Build category name lookup for human-readable keys
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Build account name lookup — `uniquingKeysWith` defends against
        // duplicate `account_id` rows from shared-account joins (we own the
        // dedup contract upstream, but a duplicate would otherwise crash
        // `Dictionary(uniqueKeysWithValues:)`).
        let accountNameById = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let accountSummaries = accounts.map { account in
            AssistantContext.AccountSummary(
                id: account.id,
                name: account.name,
                icon: account.icon,
                balance: toUnits(balance(for: account)),
                income: toUnits(accountIncome[account.id] ?? 0),
                expense: toUnits(accountExpense[account.id] ?? 0),
                currency: account.currency
            )
        }

        let categorySummaries = categories.map { cat in
            AssistantContext.CategorySummary(
                id: cat.id,
                name: cat.name,
                icon: cat.icon,
                type: cat.type.rawValue
            )
        }

        // Per-category expense totals (use category names as keys for LLM readability)
        var byCategoryKopecks: [String: Int64] = [:]
        // Per-month per-category expense totals for NL queries like "How much on cafes in March?"
        var byMonthCategoryKopecks: [String: [String: Int64]] = [:]
        var totalExpenseKopecks: Int64 = 0
        var totalIncomeKopecks: Int64 = 0

        // ADR-001: balance math uses amount_native (in account currency).
        // To aggregate across multiple accounts with different currencies
        // (e.g. RUB Семейный + USD ByBit) we FX-normalize into base first,
        // otherwise $5 gets summed into rubles as "5 ₽" — off by ~76×.
        //
        // Uses the cached FX context (kept in sync by `rebuildCurrencyContext()`).
        let ctxFx = currencyContext
        let inBase: (Transaction) -> Int64 = { tx in
            TransactionMath.amountInBase(
                tx,
                accountsById: ctxFx.accountsById,
                fxRates: ctxFx.fxRates,
                baseCode: ctxFx.baseCode
            )
        }

        for tx in transactions {
            let amount = inBase(tx)
            switch tx.type {
            case .expense:
                totalExpenseKopecks += amount
                if let catId = tx.categoryId {
                    let name = categoryNameById[catId] ?? catId
                    byCategoryKopecks[name, default: 0] += amount
                    let monthKey = String(tx.date.prefix(7))  // yyyy-MM
                    byMonthCategoryKopecks[monthKey, default: [:]][name, default: 0] += amount
                }
            case .income:
                totalIncomeKopecks += amount
            case .transfer:
                break
            }
        }

        // Per-account expense totals (use account names as keys for LLM readability)
        var byAccountKopecks: [String: Int64] = [:]
        for tx in transactions where tx.type == .expense {
            if let accId = tx.accountId {
                let name = accountNameById[accId] ?? accId
                byAccountKopecks[name, default: 0] += inBase(tx)
            }
        }

        // Convert to whole currency units
        let byCategory = byCategoryKopecks.mapValues { toUnits($0) }
        let byAccount = byAccountKopecks.mapValues { toUnits($0) }
        let byMonthCategory = byMonthCategoryKopecks.mapValues { inner in
            inner.mapValues { toUnits($0) }
        }

        // Date range
        let dates = transactions.map(\.date).sorted()
        let dateFrom = dates.first
        let dateTo = dates.last

        let summary = AssistantContext.TransactionSummary(
            totalExpense: toUnits(totalExpenseKopecks),
            totalIncome: toUnits(totalIncomeKopecks),
            byCategory: byCategory,
            byAccount: byAccount,
            byMonthCategory: byMonthCategory,
            count: transactions.count,
            dateFrom: dateFrom,
            dateTo: dateTo
        )

        // Total balance across all accounts
        let totalBalance = accounts.reduce(0.0) { sum, account in
            sum + toUnits(balance(for: account))
        }

        let currencyCode = (accounts.first?.currency ?? "RUB").uppercased()

        // Resolve the user's effective language preference:
        // `appLanguage` UserDefaults override wins, otherwise system language.
        // This determines which language the AI must respond in.
        let responseLanguage: String = {
            if let override = UserDefaults.standard.string(forKey: "appLanguage"),
               override != "system", !override.isEmpty {
                return override
            }
            return Locale.current.language.languageCode?.identifier ?? "en"
        }()

        // Subscriptions (active only), normalized to monthly rate
        let subSummaries: [AssistantContext.SubscriptionSummary] = subscriptions
            .filter { $0.status == .active }
            .map { sub in
                let monthlyAmount = BudgetMath.normalizedAmount(
                    sub.amount, from: sub.billingPeriod, to: .monthly
                )
                let catName = sub.categoryId.flatMap { categoryNameById[$0] }
                return AssistantContext.SubscriptionSummary(
                    name: sub.serviceName,
                    amountMonthly: toUnits(monthlyAmount),
                    period: sub.billingPeriod.rawValue,
                    nextPaymentDate: sub.nextPaymentDate,
                    category: catName
                )
            }

        // Budgets with computed metrics — FX-normalized via currencyContext
        // so VND/USD transactions sum correctly against the budget's own
        // currency (ADR-001).
        let ctx: BudgetMath.CurrencyContext = ctxFx
        let budgetSummaries: [AssistantContext.BudgetSummary] = budgets
            .filter { $0.isActive }
            .map { budget in
                let metrics = BudgetMath.compute(
                    budget: budget, transactions: transactions, subscriptions: subscriptions,
                    currencyContext: ctx
                )
                return AssistantContext.BudgetSummary(
                    name: budget.name,
                    limit: toUnits(metrics.effectiveLimit),
                    spent: toUnits(metrics.spent),
                    remaining: toUnits(metrics.remaining),
                    utilization: metrics.utilization,
                    period: budget.billingPeriod.rawValue,
                    status: metrics.status.rawValue,
                    subscriptionCommitted: toUnits(metrics.subscriptionCommitted)
                )
            }

        return AssistantContext(
            accounts: accountSummaries,
            categories: categorySummaries,
            transactionSummary: summary,
            totalBalance: totalBalance,
            currency: accounts.first?.currency ?? "rub",
            locale: Locale.current.identifier,
            amountUnit: "Amounts are whole units of \(currencyCode) (not minor units). 1500 means 1500 \(currencyCode).",
            subscriptions: subSummaries.isEmpty ? nil : subSummaries,
            budgets: budgetSummaries.isEmpty ? nil : budgetSummaries,
            responseLanguage: responseLanguage,
            fxRates: currencyManager?.rates,
            displayCurrency: currencyManager?.dataCurrency.code.uppercased()
        )
    }

    // MARK: - Cache

    /// Rebuild the FX-context cache (`accountsById`, `fxRatesDecimal`,
    /// `baseCurrencyCode`) from the current `accounts` array and the
    /// injected `currencyManager`. Must be called whenever any of those
    /// inputs change — `rebuildCaches()` does this for us in the data
    /// path; for FX-rate updates that arrive *after* initial load, call
    /// `currencyContextDidChange()` from the rate refresh site.
    ///
    /// Defends against duplicate `account.id` rows (shared-account joins
    /// can return the same account twice) by `uniquingKeysWith` instead of
    /// the crash-on-duplicate `Dictionary(uniqueKeysWithValues:)`.
    private func rebuildCurrencyContext() {
        baseCurrencyCode = currencyManager?.dataCurrency.code.uppercased() ?? "RUB"
        fxRatesDecimal = (currencyManager?.rates ?? [:]).mapValues { Decimal($0) }
        accountsById = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Public hook for `CurrencyManager` / `AppViewModel` to trigger a
    /// refresh of the cached FX context after rates or the base currency
    /// change. Also re-runs `rebuildCaches()` because per-account balances
    /// are stored in base currency and become stale when the FX table
    /// changes.
    func currencyContextDidChange() {
        rebuildCaches()
        writeWidgetSnapshot()
    }

    /// Rebuild all caches in one pass — call after any data change.
    ///
    /// ADR-001 + legacy-UI contract: balance_cache and per-account sums are
    /// kept in **base currency** (kopecks) because `AccountCarouselView` and
    /// friends assume `formatAmount(balance)` takes a base-currency number
    /// and FX-converts into the display currency. Math itself is done in the
    /// account's own currency (via `tx.amountNative`) and then normalized to
    /// base just before caching. Without the FX step a USD account's
    /// balance got interpreted as RUB and divided by the rate again, which
    /// is why ByBit showed "$8.42" instead of "$640".
    func rebuildCaches() {
        // Refresh the FX-context cache first so downstream getters
        // (`amountInBase`, `currencyContext`) see the same snapshot of
        // `accounts` / `currencyManager.rates` we use here.
        rebuildCurrencyContext()
        let baseCode = baseCurrencyCode
        let fxRates = fxRatesDecimal
        let accountCurrencyById: [String: String] = Dictionary(
            accounts.map { ($0.id, $0.currency.uppercased()) },
            uniquingKeysWith: { first, _ in first }
        )

        var incomeByAccount: [String: Int64] = [:]
        var expenseByAccount: [String: Int64] = [:]

        // Monthly aggregate buckets — populated in the same pass so we don't
        // walk `transactions` twice. Excludes transfers (see contract on
        // `MonthlyAggregate`).
        var monthlyGlobal: [String: (income: Int64, expense: Int64)] = [:]
        var monthlyByAccount: [String: [String: (income: Int64, expense: Int64)]] = [:]

        for tx in transactions {
            guard let accountId = tx.accountId else { continue }
            let accountCcy = accountCurrencyById[accountId] ?? baseCode
            // ADR-001: amount_native is canonical, always in account currency.
            // Normalize into base before caching so the legacy UI contract
            // (balance stored in base kopecks, FX-converted at render time)
            // keeps working.
            let amountInBase = NetWorthCalculator.convert(
                amount: tx.amountNative,
                from: accountCcy,
                to: baseCode,
                rates: fxRates
            )
            switch tx.type {
            case .income:
                incomeByAccount[accountId, default: 0] += amountInBase
            case .expense:
                expenseByAccount[accountId, default: 0] += amountInBase
            case .transfer:
                // Legacy transfer type — treat positive as income, negative as expense
                if amountInBase > 0 {
                    incomeByAccount[accountId, default: 0] += amountInBase
                } else {
                    expenseByAccount[accountId, default: 0] += abs(amountInBase)
                }
            }

            // Monthly buckets — net cashflow only. Skip both the dedicated
            // transfer type and any row that's a leg of a multi-row transfer
            // (`transferGroupId != nil`).
            guard tx.type != .transfer, tx.transferGroupId == nil else { continue }
            let monthKey = String(tx.date.prefix(7))  // yyyy-MM (UTC-consistent with tx.date)
            switch tx.type {
            case .income:
                monthlyGlobal[monthKey, default: (0, 0)].income += amountInBase
                monthlyByAccount[accountId, default: [:]][monthKey, default: (0, 0)].income += amountInBase
            case .expense:
                monthlyGlobal[monthKey, default: (0, 0)].expense += amountInBase
                monthlyByAccount[accountId, default: [:]][monthKey, default: (0, 0)].expense += amountInBase
            case .transfer:
                break  // unreachable — guarded above
            }
        }

        var cache: [String: Int64] = [:]
        for account in accounts {
            let initialInBase = NetWorthCalculator.convert(
                amount: account.initialBalance,
                from: account.currency.uppercased(),
                to: baseCode,
                rates: fxRates
            )
            let income = incomeByAccount[account.id] ?? 0
            let expense = expenseByAccount[account.id] ?? 0
            cache[account.id] = initialInBase + income - expense
        }
        balanceCache = cache
        accountIncome = incomeByAccount
        accountExpense = expenseByAccount

        // Deduplicate categories by ID only (shared accounts may return same row twice).
        // We must NOT deduplicate by name because different users may have categories
        // with the same name but different IDs, and transactions reference those IDs.
        var seenIds: Set<String> = []
        categories = categories.filter { cat in
            if seenIds.contains(cat.id) { return false }
            seenIds.insert(cat.id)
            return true
        }
        categoryIndex = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        // Materialize the monthly aggregate dictionaries from the (income, expense)
        // tuple buckets we accumulated above.
        monthlyAggregates = monthlyGlobal.reduce(into: [String: MonthlyAggregate]()) { acc, kv in
            acc[kv.key] = MonthlyAggregate(monthKey: kv.key, income: kv.value.income, expense: kv.value.expense)
        }
        monthlyAggregatesByAccount = monthlyByAccount.reduce(into: [String: [String: MonthlyAggregate]]()) { outer, kv in
            outer[kv.key] = kv.value.reduce(into: [String: MonthlyAggregate]()) { inner, mv in
                inner[mv.key] = MonthlyAggregate(monthKey: mv.key, income: mv.value.income, expense: mv.value.expense)
            }
        }

        // Bump generation token last — readers that see a new token are
        // guaranteed to see the new aggregate dictionaries too.
        txGenerationToken &+= 1
    }
}

extension DataStore {
    /// Returns the last `months` monthly aggregates, sorted chronologically
    /// (oldest first). When `accountId` is supplied, the values are scoped
    /// to that account; otherwise the global aggregates are used.
    ///
    /// Months without any non-transfer activity are filled with a zero
    /// `MonthlyAggregate` so chart x-axes don't gap. The window is anchored
    /// to the current calendar month (in UTC, matching `tx.date`'s yyyy-MM).
    func recentMonthlyAggregates(months: Int = 6, accountId: String? = nil) -> [MonthlyAggregate] {
        guard months > 0 else { return [] }

        let source: [String: MonthlyAggregate]
        if let accountId {
            source = monthlyAggregatesByAccount[accountId] ?? [:]
        } else {
            source = monthlyAggregates
        }

        // Build the month-key window ending at "now" (UTC, yyyy-MM).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var keys: [String] = []
        keys.reserveCapacity(months)
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            keys.append(formatter.string(from: date))
        }

        return keys.map { key in
            source[key] ?? MonthlyAggregate(monthKey: key, income: 0, expense: 0)
        }
    }
}
