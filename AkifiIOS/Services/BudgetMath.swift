import Foundation

enum RiskLevel: String { case low, medium, high, critical }
enum BudgetStatus: String { case onTrack, warning, nearLimit, overLimit }

struct BudgetMetrics {
    let spent: Int64
    let effectiveLimit: Int64
    let remaining: Int64
    let utilization: Int          // 0–999 %
    let totalDays: Int
    let elapsedDays: Int
    let remainingDays: Int
    let safeToSpendDaily: Int64
    let paceRatio: Double         // 1.0 = on track
    let riskLevel: RiskLevel
    let status: BudgetStatus
    let progressColor: String     // hex
    let subscriptionCommitted: Int64
    let freeRemaining: Int64
    /// Rollover carried into this period (minor units of the budget
    /// currency), already included in `effectiveLimit`. 0 without rollover.
    var carryIn: Int64 = 0
    /// The window these numbers cover (local midnight). The card labels
    /// THIS window — «19 окт – 17 ноя» — not a calendar month (D4).
    var periodStart: Date = .distantPast
    var periodEnd: Date = .distantPast
}

/// Budget math. Since 2026-11-17 the server (`get_budget_metrics`,
/// migration 20261117130003) is the source of truth — it sees every
/// member's rows, so a shared budget shows the same numbers to everyone.
/// This file is the offline fallback and the cross-check, and the server SQL
/// mirrors it rule for rule: change one, change the other.
enum BudgetMath {

    /// Alias of `TransactionMath.CurrencyContext` so existing call sites
    /// that reference `BudgetMath.CurrencyContext` keep working while the
    /// canonical spelling lives with the math helper itself.
    typealias CurrencyContext = TransactionMath.CurrencyContext

    /// Gregorian in the device zone — never the user's display calendar
    /// (a Buddhist-calendar iPhone must not shift periods, D1).
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// The currency the budget's `amount` — and therefore every value in
    /// its `BudgetMetrics` — is denominated in. Resolution order:
    ///   1. `budget.currency` — NOT NULL on the server since migration
    ///      20261117130002; nil only in caches written before it.
    ///   2. The linked account's currency, when `budget.accountId` is set.
    ///   3. The user's base currency — legacy default.
    static func budgetCurrency(for budget: Budget, currencyContext: CurrencyContext) -> String {
        if let explicit = budget.currency, !explicit.isEmpty {
            return explicit.uppercased()
        }
        if let accId = budget.accountId,
           let acc = currencyContext.accountsById[accId] {
            return acc.currency.uppercased()
        }
        return currencyContext.baseCode
    }

    /// Converts a budget-local amount (minor units in the budget's own
    /// currency) into the base currency. Required before aggregating
    /// across budgets — their metrics are denominated per budget, so a
    /// 4 000 000 VND limit must not be added to RUB kopecks as-is.
    static func amountInBase(_ amount: Int64, budget: Budget, currencyContext: CurrencyContext) -> Int64 {
        NetWorthCalculator.convert(
            amount: amount,
            from: budgetCurrency(for: budget, currencyContext: currencyContext),
            to: currencyContext.baseCode,
            rates: currencyContext.fxRates
        )
    }

    static func compute(
        budget: Budget,
        transactions: [Transaction],
        subscriptions: [SubscriptionTracker] = [],
        categories: [Category] = [],
        externalSpendRows: [ExternalSpendRow] = [],
        currencyContext: CurrencyContext,
        now: Date = Date(),
        period overridePeriod: (start: Date, end: Date)? = nil
    ) -> BudgetMetrics {
        let period = overridePeriod ?? currentPeriod(for: budget, now: now)
        let spent = spentAmount(budget: budget, transactions: transactions, period: period, categories: categories, currencyContext: currencyContext)
            + externalSpent(rows: externalSpendRows, budget: budget, period: period, currencyContext: currencyContext)
        let carry = rolloverCarry(
            budget: budget, currentPeriod: period, transactions: transactions,
            categories: categories, externalSpendRows: externalSpendRows,
            currencyContext: currencyContext
        )
        let subCommitted = subscriptionCommitted(
            budget: budget, subscriptions: subscriptions, categories: categories, currencyContext: currencyContext
        )
        return assemble(
            limit: budget.amount, carryIn: carry, spent: spent,
            subscriptionCommitted: subCommitted, period: period, today: now
        )
    }

    /// Derives every metric from its inputs. Shared by the local path, the
    /// server-backed path when local data moved since the last fetch, and
    /// tests — one set of formulas (and the server SQL mirrors them).
    static func assemble(
        limit: Int64,
        carryIn: Int64,
        spent: Int64,
        subscriptionCommitted subCommitted: Int64,
        period: (start: Date, end: Date),
        today: Date
    ) -> BudgetMetrics {
        let effective = limit + carryIn
        let remaining = max(0, effective - spent)
        let freeRemaining = max(0, remaining - subCommitted)

        let utilization = computeProgress(spent: spent, limit: effective)
        let days = daysMeta(start: period.start, end: period.end, today: today)
        let safe = computeSafeToSpend(limit: effective, spent: spent + subCommitted, remainingDays: days.remaining)
        let pace = computePace(limit: effective, spent: spent, elapsed: days.elapsed, total: days.total)
        let risk = computeRiskLevel(utilization: utilization, pace: pace, remainingDays: days.remaining)
        let status = computeStatus(utilization: utilization, pace: pace)
        let color = progressColorHex(utilization: utilization)

        return BudgetMetrics(
            spent: spent, effectiveLimit: effective, remaining: remaining,
            utilization: utilization,
            totalDays: days.total, elapsedDays: days.elapsed, remainingDays: days.remaining,
            safeToSpendDaily: safe, paceRatio: pace,
            riskLevel: risk, status: status, progressColor: color,
            subscriptionCommitted: subCommitted, freeRemaining: freeRemaining,
            carryIn: carryIn,
            periodStart: period.start, periodEnd: period.end
        )
    }

    /// Metrics exactly as the server computed them. Presentation-only
    /// fields (risk, status, colour) derive from the server's utilization /
    /// pace / remaining days with the same thresholds as everywhere else.
    static func metrics(fromServer s: ServerBudgetMetrics) -> BudgetMetrics {
        let period = s.period ?? (.distantPast, .distantPast)
        return BudgetMetrics(
            spent: s.spent, effectiveLimit: s.effectiveLimit, remaining: s.remaining,
            utilization: s.utilization,
            totalDays: s.totalDays, elapsedDays: s.elapsedDays, remainingDays: s.remainingDays,
            safeToSpendDaily: s.safeToSpendDaily, paceRatio: s.paceRatio,
            riskLevel: computeRiskLevel(utilization: s.utilization, pace: s.paceRatio, remainingDays: s.remainingDays),
            status: computeStatus(utilization: s.utilization, pace: s.paceRatio),
            progressColor: progressColorHex(utilization: s.utilization),
            subscriptionCommitted: s.subscriptionCommitted, freeRemaining: s.freeRemaining,
            carryIn: s.carryIn,
            periodStart: period.start, periodEnd: period.end
        )
    }

    // MARK: - Period

    static func currentPeriod(for budget: Budget, now: Date = Date()) -> (start: Date, end: Date) {
        let cal = calendar
        switch budget.billingPeriod {
        case .weekly:
            let weekday = cal.component(.weekday, from: now)
            let daysToMonday = (weekday + 5) % 7
            let start = cal.date(byAdding: .day, value: -daysToMonday, to: cal.startOfDay(for: now))!
            let end = cal.date(byAdding: .day, value: 6, to: start)!
            return (start, end)
        case .monthly:
            // 30-day rolling window anchored to the budget's created_at.
            // A user creating a monthly budget on the 19th expects a full
            // 30-day cycle, not "10 days until the calendar month flips".
            // Falls back to calendar-month for legacy budgets without a
            // parseable created_at.
            let periodLen = 30
            if let created = Self.parseCreatedAt(budget.createdAt) {
                let startOfDayCreated = cal.startOfDay(for: created)
                let startOfDayNow = cal.startOfDay(for: now)
                let daysSince = cal.dateComponents([.day], from: startOfDayCreated, to: startOfDayNow).day ?? 0
                let periodIndex = max(0, daysSince) / periodLen
                let start = cal.date(byAdding: .day, value: periodIndex * periodLen, to: startOfDayCreated)!
                let end = cal.date(byAdding: .day, value: periodLen - 1, to: start)!
                return (start, end)
            }
            return calendarMonth(containing: now, calendar: cal)
        case .quarterly:
            let month = cal.component(.month, from: now)
            let qStart = ((month - 1) / 3) * 3 + 1
            var comps = cal.dateComponents([.year], from: now)
            comps.month = qStart; comps.day = 1
            let start = cal.date(from: comps)!
            let end = cal.date(byAdding: DateComponents(month: 3, day: -1), to: start)!
            return (start, end)
        case .yearly:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            let end = cal.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
            return (start, end)
        case .custom:
            let df = AppDateFormatters.isoDate
            if let startStr = budget.customStartDate,
               let endStr = budget.customEndDate,
               let start = df.date(from: startStr),
               let end = df.date(from: endStr) {
                return (start, end)
            }
            return calendarMonth(containing: now, calendar: cal)
        }
    }

    private static func calendarMonth(containing now: Date, calendar cal: Calendar) -> (start: Date, end: Date) {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
        return (start, end)
    }

    /// The period right before `currentStart`, or nil when there is none:
    /// custom budgets, the first rolling window, or a previous period the
    /// budget didn't exist for in full (same rule as the server).
    static func previousPeriod(for budget: Budget, currentStart: Date) -> (start: Date, end: Date)? {
        let cal = calendar
        let anchor = parseCreatedAt(budget.createdAt).map { cal.startOfDay(for: $0) }
        let previous: (start: Date, end: Date)
        switch budget.billingPeriod {
        case .custom:
            return nil
        case .monthly where anchor != nil:
            let start = cal.date(byAdding: .day, value: -30, to: currentStart)!
            previous = (start, cal.date(byAdding: .day, value: -1, to: currentStart)!)
        default:
            let dayBefore = cal.date(byAdding: .day, value: -1, to: currentStart)!
            previous = currentPeriod(for: budget, now: dayBefore)
        }
        if let anchor, anchor > previous.start { return nil }
        return previous
    }

    /// Rollover (M10): the previous period's leftover, never negative.
    /// The server additionally honours a `budget_rollovers` ledger row the
    /// Mini App may write; RLS hides those rows from partners, so the
    /// client fallback only does the computed carry.
    static func rolloverCarry(
        budget: Budget,
        currentPeriod period: (start: Date, end: Date),
        transactions: [Transaction],
        categories: [Category],
        externalSpendRows: [ExternalSpendRow],
        currencyContext: CurrencyContext
    ) -> Int64 {
        guard budget.rolloverEnabled,
              let previous = previousPeriod(for: budget, currentStart: period.start) else { return 0 }
        let prevSpent = spentAmount(budget: budget, transactions: transactions, period: previous,
                                    categories: categories, currencyContext: currencyContext)
            + externalSpent(rows: externalSpendRows, budget: budget, period: previous,
                            currencyContext: currencyContext)
        return max(0, budget.amount - prevSpent)
    }

    // MARK: - Forecast Overrun Date

    static func forecastOverrunDate(metrics: BudgetMetrics) -> Date? {
        guard metrics.spent > 0, metrics.elapsedDays > 0, metrics.spent < metrics.effectiveLimit else { return nil }
        let dailyRate = Double(metrics.spent) / Double(metrics.elapsedDays)
        guard dailyRate > 0 else { return nil }
        let daysToOverrun = Double(metrics.effectiveLimit - metrics.spent) / dailyRate
        guard daysToOverrun < Double(metrics.remainingDays) else { return nil }
        return calendar.date(byAdding: .day, value: Int(daysToOverrun), to: Date())
    }

    // MARK: - Spent

    /// Sums the transactions matching this budget, FX-normalizing each
    /// amount_native into the budget's currency. Resolution order for the
    /// budget's denominating currency:
    ///   1. `budget.currency` — set explicitly when the user picks one in
    ///      `BudgetFormView` (per-budget multi-currency support).
    ///   2. The linked account's currency, when `budget.accountId` is set
    ///      and there is no explicit override.
    ///   3. The user's base currency — legacy default for budgets created
    ///      before the currency picker existed.
    static func spentAmount(
        budget: Budget,
        transactions: [Transaction],
        period: (start: Date, end: Date),
        categories: [Category] = [],
        currencyContext: CurrencyContext
    ) -> Int64 {
        let budgetCurrency = budgetCurrency(for: budget, currencyContext: currencyContext)

        return matchingTransactions(
            budget: budget, transactions: transactions, period: period, categories: categories
        ).reduce(Int64(0)) { acc, tx in
            acc + TransactionMath.amountInBase(
                tx,
                accountsById: currencyContext.accountsById,
                fxRates: currencyContext.fxRates,
                baseCode: budgetCurrency
            )
        }
    }

    /// Spent on one calendar day (own visible rows + partner rows) in the
    /// budget currency — the widget's «потрачено сегодня» offline fallback,
    /// with exactly the card's matching rules (B8).
    static func spentOnDay(
        _ day: Date,
        budget: Budget,
        transactions: [Transaction],
        categories: [Category] = [],
        externalSpendRows: [ExternalSpendRow] = [],
        currencyContext: CurrencyContext
    ) -> Int64 {
        let start = calendar.startOfDay(for: day)
        let period = (start: start, end: start)
        return spentAmount(budget: budget, transactions: transactions, period: period,
                           categories: categories, currencyContext: currencyContext)
            + externalSpent(rows: externalSpendRows, budget: budget, period: period,
                            currencyContext: currencyContext)
    }

    /// The expenses that make up `spentAmount` — same category, account and
    /// period rules, newest first. `spentAmount` sums exactly this list, so
    /// the budget's history sheet can never disagree with the number on the
    /// card (the failure mode the reports drill-down had).
    ///
    /// Note the amounts are NOT FX-normalized here: rows keep their own
    /// currency for display, and only the sum needs a common denominator.
    static func matchingTransactions(
        budget: Budget,
        transactions: [Transaction],
        period: (start: Date, end: Date),
        categories: [Category] = []
    ) -> [Transaction] {
        let categoryMatcher = CategoryMatcher(budgetCategoryIds: budget.categoryIds, categories: categories)
        // `Transaction.date` is stored as "yyyy-MM-dd" (truncated on decode),
        // so lexicographic order IS chronological order. Comparing strings
        // avoids a DateFormatter parse per row — this runs for every budget
        // on every render, and parsing ~1500 dates each time showed up as
        // stutter on the budgets tab.
        let startKey = AppDateFormatters.isoDate.string(from: period.start)
        let endKey = AppDateFormatters.isoDate.string(from: period.end)
        // A linked-account list is usually 1-2 entries, but Set lookup keeps
        // the inner loop O(1) regardless.
        let accountIds = budget.accountIds.map(Set.init) ?? []

        return transactions.filter { tx in
            guard tx.type == .expense && !tx.isTransfer else { return false }
            guard tx.date >= startKey && tx.date <= endKey else { return false }
            guard categoryMatcher.matches(tx.categoryId) else { return false }
            // ALL linked accounts count, not just the first — a shared
            // budget spanning several accounts must see spending on each.
            if !accountIds.isEmpty {
                guard let a = tx.accountId, accountIds.contains(a) else { return false }
            }
            return true
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - External spend (shared budgets)

    /// A partner's budget-relevant expense that the caller's RLS can't see
    /// (paid from an account not shared with the caller). Fetched via the
    /// `get_budget_member_expenses` RPC — the server already applied the
    /// budget's category/account rules and the visibility dedup, so the
    /// client only re-buckets by period and FX-normalizes.
    struct ExternalSpendRow: Codable, Sendable, Identifiable {
        /// Transaction uuid (RPC v2, migration 20260910120000). A bare id
        /// leaks nothing about the partner's spending; it exists so
        /// `SupabasePaging` has a total order and a dedupe key.
        let txId: String
        /// Main units (Decimal, matches the DB numeric).
        let amountNative: Decimal
        /// The paying account's currency (may be lowercase from legacy rows).
        let currency: String
        /// "yyyy-MM-dd"
        let txDate: String

        var id: String { txId }

        enum CodingKeys: String, CodingKey {
            case txId = "tx_id"
            case amountNative = "amount_native"
            case currency
            case txDate = "tx_date"
        }
    }

    /// Sums the partner rows falling into the budget's current period,
    /// FX-normalized into the budget's currency — the invisible remainder
    /// added on top of the locally computed `spentAmount`.
    static func externalSpent(
        rows: [ExternalSpendRow],
        budget: Budget,
        period: (start: Date, end: Date),
        currencyContext: CurrencyContext
    ) -> Int64 {
        guard !rows.isEmpty else { return 0 }

        let budgetCurrency = budgetCurrency(for: budget, currencyContext: currencyContext)

        // Same string comparison as `matchingTransactions` — inclusive on
        // both ends, no per-row date parsing.
        let startKey = AppDateFormatters.isoDate.string(from: period.start)
        let endKey = AppDateFormatters.isoDate.string(from: period.end)
        var total: Int64 = 0
        for row in rows {
            let day = String(row.txDate.prefix(10))
            guard day >= startKey && day <= endKey else { continue }
            total += NetWorthCalculator.convert(
                amount: row.amountNative.kopecks,
                from: row.currency.uppercased(),
                to: budgetCurrency,
                rates: currencyContext.fxRates
            )
        }
        return total
    }

    /// Category filter that also matches by NAME, not only by id.
    ///
    /// On shared accounts (and now shared budgets) each user has their own
    /// category rows — the partner's «Продукты» has a different id, so pure
    /// id-matching silently drops their spending from the budget. Reports
    /// already merge same-name categories (`ReportsViewModel.categoryBreakdown`);
    /// this mirrors that rule. With no `categories` list supplied the matcher
    /// degrades to the legacy id-only behavior.
    struct CategoryMatcher {
        private let budgetIds: Set<String>
        private let budgetNames: Set<String>
        private let nameById: [String: String]

        init(budgetCategoryIds: [String]?, categories: [Category]) {
            let ids = Set(budgetCategoryIds ?? [])
            budgetIds = ids
            guard !ids.isEmpty, !categories.isEmpty else {
                budgetNames = []
                nameById = [:]
                return
            }
            var names: [String: String] = [:]
            names.reserveCapacity(categories.count)
            for cat in categories {
                names[cat.id] = Self.normalized(cat.name)
            }
            nameById = names
            budgetNames = Set(ids.compactMap { names[$0] })
        }

        /// True when the budget has no category filter, or the transaction's
        /// category matches by id or by normalized name.
        func matches(_ categoryId: String?) -> Bool {
            guard !budgetIds.isEmpty else { return true }
            guard let categoryId else { return false }
            if budgetIds.contains(categoryId) { return true }
            guard let name = nameById[categoryId] else { return false }
            return budgetNames.contains(name)
        }

        private static func normalized(_ name: String) -> String {
            name.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Subscription Committed

    /// Sum of the user's active subscriptions committed against this
    /// budget's period, FX-normalized into the budget's currency.
    /// Without the FX step a $9.99/mo subscription on a RUB budget gets
    /// added as 9.99 roubles instead of ~925 — silently understating the
    /// committed total by two orders of magnitude.
    ///
    /// Offline fallback only sees THIS user's subscriptions (RLS); the
    /// server counts every member's (B3).
    static func subscriptionCommitted(
        budget: Budget,
        subscriptions: [SubscriptionTracker],
        categories: [Category] = [],
        currencyContext: CurrencyContext
    ) -> Int64 {
        let activeSubs = subscriptions.filter { $0.status == .active }
        guard !activeSubs.isEmpty else { return 0 }

        let budgetCurrency = budgetCurrency(for: budget, currencyContext: currencyContext)

        let categoryMatcher = CategoryMatcher(budgetCategoryIds: budget.categoryIds, categories: categories)

        var total: Int64 = 0
        for sub in activeSubs {
            guard categoryMatcher.matches(sub.categoryId) else { continue }
            let periodNormalized = normalizedAmount(
                sub.amount, from: sub.billingPeriod, to: budget.billingPeriod
            )
            let subCurrency = (sub.currency ?? currencyContext.baseCode).uppercased()
            let fxNormalized = NetWorthCalculator.convert(
                amount: periodNormalized,
                from: subCurrency,
                to: budgetCurrency,
                rates: currencyContext.fxRates
            )
            total += fxNormalized
        }
        return total
    }

    /// Monthly-equivalent total of every **active** subscription,
    /// FX-normalized into the base currency. Paused and cancelled trackers
    /// are not billing, so they stay out — same rule as
    /// `subscriptionCommitted`. The FX step is not optional: without it a
    /// $200/mo tracker lands in RUB kopecks as 200 ₽ (ADR-001).
    static func activeSubscriptionsMonthlyTotalInBase(
        subscriptions: [SubscriptionTracker],
        currencyContext: CurrencyContext
    ) -> Int64 {
        subscriptions
            .filter { $0.status == .active }
            .reduce(Int64(0)) { total, sub in
                let monthly = normalizedAmount(sub.amount, from: sub.billingPeriod, to: .monthly)
                return total + NetWorthCalculator.convert(
                    amount: monthly,
                    from: (sub.currency ?? currencyContext.baseCode).uppercased(),
                    to: currencyContext.baseCode,
                    rates: currencyContext.fxRates
                )
            }
    }

    static func normalizedAmount(_ amount: Int64, from: BillingPeriod, to: BillingPeriod) -> Int64 {
        if from == to { return amount }
        let monthly = monthlyEquivalent(amount, period: from)
        return fromMonthly(monthly, period: to)
    }

    private static func monthlyEquivalent(_ amount: Int64, period: BillingPeriod) -> Double {
        switch period {
        case .weekly: return Double(amount) * 52.0 / 12.0
        case .monthly: return Double(amount)
        case .quarterly: return Double(amount) / 3.0
        case .yearly: return Double(amount) / 12.0
        case .custom: return Double(amount)
        }
    }

    private static func fromMonthly(_ monthly: Double, period: BillingPeriod) -> Int64 {
        switch period {
        case .weekly: return Int64(monthly * 12.0 / 52.0)
        case .monthly: return Int64(monthly)
        case .quarterly: return Int64(monthly * 3.0)
        case .yearly: return Int64(monthly * 12.0)
        case .custom: return Int64(monthly)
        }
    }

    /// Supabase stores `created_at` as ISO-8601 with or without fractional
    /// seconds; `AppDateFormatters.parseTimestamp` reads both (and allocates
    /// no formatter per call — that was measurable on the budgets tab, P5).
    static func parseCreatedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return AppDateFormatters.parseTimestamp(raw)
    }

    // MARK: - Daily safe-to-spend across budgets

    /// The recommended daily limit: the MINIMUM safe-to-spend-per-day across
    /// all budgets (the most restrictive budget wins), in the BASE currency
    /// (display units). Each budget's allowance is converted before the
    /// comparison — a $15.90/day USD budget must not beat 3 000 ₽/day as
    /// "15.90" (M6). Budgets whose period already ended (`remainingDays ==
    /// 0`) are skipped. Zero when there are no budgets; never negative.
    static func minDailySafeToSpend(
        budgets: [Budget],
        transactions: [Transaction],
        categories: [Category] = [],
        externalSpendByBudget: [String: [ExternalSpendRow]] = [:],
        currencyContext: CurrencyContext
    ) -> Decimal {
        let items = budgets.map { budget in
            (budget, compute(
                budget: budget,
                transactions: transactions,
                categories: categories,
                externalSpendRows: externalSpendByBudget[budget.id] ?? [],
                currencyContext: currencyContext
            ))
        }
        return minDailySafeToSpend(items, currencyContext: currencyContext)
    }

    /// Same as above for metrics already resolved (server or local).
    static func minDailySafeToSpend(
        _ items: [(budget: Budget, metrics: BudgetMetrics)],
        currencyContext: CurrencyContext
    ) -> Decimal {
        var minDaily: Int64?
        for item in items {
            guard item.metrics.remainingDays > 0 else { continue }
            let daily = amountInBase(item.metrics.safeToSpendDaily, budget: item.budget, currencyContext: currencyContext)
            minDaily = minDaily.map { min($0, daily) } ?? daily
        }
        return max(0, minDaily ?? 0).displayAmount
    }

    // MARK: - Progress (0–999 %)

    static func computeProgress(spent: Int64, limit: Int64) -> Int {
        guard limit > 0 else { return spent > 0 ? 999 : 0 }
        return min(999, max(0, Int(Double(spent) / Double(limit) * 100)))
    }

    // MARK: - Days

    /// Whole calendar days (D5). `elapsed` counts the start through today,
    /// `remaining` counts today through the end — today is in both, because
    /// today's allowance is still spendable. The old `round(interval /
    /// 86 400)` hit 0 remaining a day and a half before the end, so the
    /// daily limit showed a red zero for the last days of every period.
    static func daysMeta(start: Date, end: Date, today: Date = Date()) -> (total: Int, elapsed: Int, remaining: Int) {
        let cal = calendar
        let s = cal.startOfDay(for: start)
        let e = cal.startOfDay(for: end)
        let t = cal.startOfDay(for: today)
        let total = max(1, (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1)
        let sinceStart = cal.dateComponents([.day], from: s, to: t).day ?? 0
        let untilEnd = cal.dateComponents([.day], from: t, to: e).day ?? 0
        let elapsed = min(total, max(0, sinceStart + 1))
        let remaining = min(total, max(0, untilEnd + 1))
        return (total, elapsed, remaining)
    }

    // MARK: - Safe to spend daily

    static func computeSafeToSpend(limit: Int64, spent: Int64, remainingDays: Int) -> Int64 {
        let leftover = max(0, limit - spent)
        guard remainingDays > 0 else { return leftover }
        return max(0, leftover / Int64(remainingDays))
    }

    // MARK: - Pace ratio

    static func computePace(limit: Int64, spent: Int64, elapsed: Int, total: Int) -> Double {
        guard elapsed > 0, total > 0 else { return 0 }
        let expected = Double(limit) * (Double(elapsed) / Double(total))
        guard expected > 0 else { return spent > 0 ? 9.99 : 0 }
        return (Double(spent) / expected * 100).rounded() / 100
    }

    // MARK: - Risk level

    static func computeRiskLevel(utilization: Int, pace: Double, remainingDays: Int) -> RiskLevel {
        if utilization >= 100 || (pace >= 1.5 && remainingDays <= 3) { return .critical }
        if utilization >= 90 || (pace >= 1.3 && remainingDays <= 7) { return .high }
        if utilization >= 70 || pace >= 1.1 { return .medium }
        return .low
    }

    // MARK: - Status

    static func computeStatus(utilization: Int, pace: Double) -> BudgetStatus {
        if utilization >= 100 { return .overLimit }
        if utilization >= 90 { return .nearLimit }
        if utilization >= 75 || pace >= 1.15 { return .warning }
        return .onTrack
    }

    // MARK: - Color

    static func progressColorHex(utilization: Int) -> String {
        if utilization > 100 { return "#EF4444" }
        if utilization >= 90 { return "#F97316" }
        if utilization >= 75 { return "#F59E0B" }
        return "#22C55E"
    }
}
