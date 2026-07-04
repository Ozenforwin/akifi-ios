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
}

enum BudgetMath {

    /// Alias of `TransactionMath.CurrencyContext` so existing call sites
    /// that reference `BudgetMath.CurrencyContext` keep working while the
    /// canonical spelling lives with the math helper itself.
    typealias CurrencyContext = TransactionMath.CurrencyContext

    static func compute(
        budget: Budget,
        transactions: [Transaction],
        subscriptions: [SubscriptionTracker] = [],
        categories: [Category] = [],
        externalSpendRows: [ExternalSpendRow] = [],
        currencyContext: CurrencyContext
    ) -> BudgetMetrics {
        let period = currentPeriod(for: budget)
        let spent = spentAmount(budget: budget, transactions: transactions, period: period, categories: categories, currencyContext: currencyContext)
            + externalSpent(rows: externalSpendRows, budget: budget, period: period, currencyContext: currencyContext)
        let limit = budget.amount
        let remaining = max(0, limit - spent)

        let subCommitted = subscriptionCommitted(
            budget: budget, subscriptions: subscriptions, categories: categories, currencyContext: currencyContext
        )
        let freeRemaining = max(0, remaining - subCommitted)

        let utilization = computeProgress(spent: spent, limit: limit)
        let days = daysMeta(start: period.start, end: period.end)
        let safe = computeSafeToSpend(limit: limit, spent: spent + subCommitted, remainingDays: days.remaining)
        let pace = computePace(limit: limit, spent: spent, elapsed: days.elapsed, total: days.total)
        let risk = computeRiskLevel(utilization: utilization, pace: pace, remainingDays: days.remaining)
        let status = computeStatus(utilization: utilization, pace: pace)
        let color = progressColorHex(utilization: utilization)

        return BudgetMetrics(
            spent: spent, effectiveLimit: limit, remaining: remaining,
            utilization: utilization,
            totalDays: days.total, elapsedDays: days.elapsed, remainingDays: days.remaining,
            safeToSpendDaily: safe, paceRatio: pace,
            riskLevel: risk, status: status, progressColor: color,
            subscriptionCommitted: subCommitted, freeRemaining: freeRemaining
        )
    }

    // MARK: - Period

    static func currentPeriod(for budget: Budget) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
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
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return (start, end)
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
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return (start, end)
        }
    }

    // MARK: - Forecast Overrun Date

    static func forecastOverrunDate(metrics: BudgetMetrics) -> Date? {
        guard metrics.spent > 0, metrics.elapsedDays > 0, metrics.spent < metrics.effectiveLimit else { return nil }
        let dailyRate = Double(metrics.spent) / Double(metrics.elapsedDays)
        guard dailyRate > 0 else { return nil }
        let daysToOverrun = Double(metrics.effectiveLimit - metrics.spent) / dailyRate
        guard daysToOverrun < Double(metrics.remainingDays) else { return nil }
        return Calendar.current.date(byAdding: .day, value: Int(daysToOverrun), to: Date())
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
        let budgetCurrency: String = {
            if let explicit = budget.currency, !explicit.isEmpty {
                return explicit.uppercased()
            }
            if let accId = budget.accountId,
               let acc = currencyContext.accountsById[accId] {
                return acc.currency.uppercased()
            }
            return currencyContext.baseCode
        }()

        let categoryMatcher = CategoryMatcher(budgetCategoryIds: budget.categoryIds, categories: categories)

        let df = AppDateFormatters.isoDate
        return transactions.filter { tx in
            guard tx.type == .expense && !tx.isTransfer else { return false }
            guard categoryMatcher.matches(tx.categoryId) else { return false }
            // ALL linked accounts count, not just the first — a shared
            // budget spanning several accounts must see spending on each.
            if let accIds = budget.accountIds, !accIds.isEmpty {
                guard let a = tx.accountId, accIds.contains(a) else { return false }
            }
            guard let d = df.date(from: tx.date) else { return false }
            return d >= period.start && d <= period.end
        }.reduce(Int64(0)) { acc, tx in
            acc + TransactionMath.amountInBase(
                tx,
                accountsById: currencyContext.accountsById,
                fxRates: currencyContext.fxRates,
                baseCode: budgetCurrency
            )
        }
    }

    // MARK: - External spend (shared budgets)

    /// A partner's budget-relevant expense that the caller's RLS can't see
    /// (paid from an account not shared with the caller). Fetched via the
    /// `get_budget_member_expenses` RPC — the server already applied the
    /// budget's category/account rules and the visibility dedup, so the
    /// client only re-buckets by period and FX-normalizes.
    struct ExternalSpendRow: Codable, Sendable {
        /// Main units (Decimal, matches the DB numeric).
        let amountNative: Decimal
        /// The paying account's currency (may be lowercase from legacy rows).
        let currency: String
        /// "yyyy-MM-dd"
        let txDate: String

        enum CodingKeys: String, CodingKey {
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

        let budgetCurrency: String = {
            if let explicit = budget.currency, !explicit.isEmpty {
                return explicit.uppercased()
            }
            if let accId = budget.accountId,
               let acc = currencyContext.accountsById[accId] {
                return acc.currency.uppercased()
            }
            return currencyContext.baseCode
        }()

        let df = AppDateFormatters.isoDate
        var total: Int64 = 0
        for row in rows {
            guard let d = df.date(from: row.txDate),
                  d >= period.start && d <= period.end else { continue }
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
    static func subscriptionCommitted(
        budget: Budget,
        subscriptions: [SubscriptionTracker],
        categories: [Category] = [],
        currencyContext: CurrencyContext
    ) -> Int64 {
        let activeSubs = subscriptions.filter { $0.status == .active }
        guard !activeSubs.isEmpty else { return 0 }

        let budgetCurrency: String = {
            if let explicit = budget.currency, !explicit.isEmpty {
                return explicit.uppercased()
            }
            if let accId = budget.accountId,
               let acc = currencyContext.accountsById[accId] {
                return acc.currency.uppercased()
            }
            return currencyContext.baseCode
        }()

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

    /// Supabase stores `created_at` as ISO-8601 with fractional seconds.
    /// Accept both the fractional + plain variants.
    static func parseCreatedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Daily safe-to-spend across budgets

    /// The recommended daily limit: the MINIMUM safe-to-spend-per-day across
    /// all budgets (the most restrictive budget wins). Budgets whose period
    /// already ended (`remainingDays == 0`) are skipped. Zero when there are
    /// no budgets; never negative.
    static func minDailySafeToSpend(
        budgets: [Budget],
        transactions: [Transaction],
        categories: [Category] = [],
        externalSpendByBudget: [String: [ExternalSpendRow]] = [:],
        currencyContext: CurrencyContext
    ) -> Decimal {
        guard !budgets.isEmpty else { return 0 }

        var minDaily: Decimal?
        for budget in budgets {
            let metrics = compute(
                budget: budget,
                transactions: transactions,
                categories: categories,
                externalSpendRows: externalSpendByBudget[budget.id] ?? [],
                currencyContext: currencyContext
            )
            guard metrics.remainingDays > 0 else { continue }
            let daily = metrics.remaining.displayAmount / Decimal(metrics.remainingDays)
            minDaily = minDaily.map { min($0, daily) } ?? daily
        }

        return max(0, minDaily ?? 0)
    }

    // MARK: - Progress (0–999 %)

    static func computeProgress(spent: Int64, limit: Int64) -> Int {
        guard limit > 0 else { return spent > 0 ? 999 : 0 }
        return min(999, max(0, Int(Double(spent) / Double(limit) * 100)))
    }

    // MARK: - Days

    static func daysMeta(start: Date, end: Date) -> (total: Int, elapsed: Int, remaining: Int) {
        let day: TimeInterval = 86_400
        let total = max(1, Int(round((end.timeIntervalSince(start)) / day)) + 1)
        let elapsed = max(0, min(total, Int(round((Date().timeIntervalSince(start)) / day)) + 1))
        return (total, elapsed, total - elapsed)
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
