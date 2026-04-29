import Foundation

/// Pure savings-rate aggregator. Wraps `CashFlowEngine.monthlyBuckets`
/// so the FIRE projection consumes the same buckets users already see
/// in the Cash-Flow forecast and we don't end up with two separate
/// notions of "savings rate" drifting apart.
///
/// What it does:
/// 1. Filters out subscription-linked expense rows (they get summed
///    separately via `monthlySubscriptionCost`).
/// 2. Walks the last `lookbackMonths` months (default 3) using
///    `monthlyBuckets`.
/// 3. Returns averaged monthly income, expense (excl. subs),
///    sub cost, net savings = income − expense − subs, and the
///    fractional savings rate (= netSavings / income). Plus
///    `Confidence` from CashFlowEngine.confidence so the UI can grey
///    out / hide the FIRE number when stats are too thin.
///
/// Money sums are normalized into the user's base currency in minor
/// units (kopecks), same as `CashFlowEngine.monthlyBuckets`.
enum SavingsRateCalculator {

    struct Snapshot: Sendable, Equatable {
        let avgMonthlyIncome: Int64
        let avgMonthlyExpense: Int64
        let monthlySubscriptionCost: Int64
        /// `avgMonthlyIncome − avgMonthlyExpense − monthlySubscriptionCost`.
        /// Can be negative (the user is in the red).
        let avgMonthlyNet: Int64
        /// `netSavings / income` as a fraction (`0.25` = 25%).
        /// `nil` when avgMonthlyIncome ≤ 0 (no income, no rate).
        let savingsRate: Decimal?
        /// How many of the last `lookback` months had any activity.
        /// Drives `confidence` and the "need more data" UI state.
        let sampleMonths: Int
        let confidence: CashFlowEngine.Confidence

        static let empty = Snapshot(
            avgMonthlyIncome: 0,
            avgMonthlyExpense: 0,
            monthlySubscriptionCost: 0,
            avgMonthlyNet: 0,
            savingsRate: nil,
            sampleMonths: 0,
            confidence: .low
        )
    }

    /// Compute the savings-rate snapshot.
    ///
    /// - Parameters:
    ///   - transactions: full transaction history. Filtering is done here.
    ///   - subscriptions: active subs, used to drop subscription-linked
    ///     expenses and to compute the average monthly sub cost.
    ///   - lookbackMonths: 1-12. Default 3.
    ///   - now: injectable clock for tests.
    ///   - calendar: injectable calendar for tests.
    ///   - accountsById / fxRates / baseCode: pass-through to
    ///     `monthlyBuckets` so amounts are FX-normalised.
    static func compute(
        transactions: [Transaction],
        subscriptions: [SubscriptionTracker],
        lookbackMonths: Int = 3,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        accountsById: [String: Account] = [:],
        fxRates: [String: Decimal] = [:],
        baseCode: String = "RUB"
    ) -> Snapshot {
        let bounded = max(1, min(12, lookbackMonths))

        // Drop sub-linked expenses so they don't double-count with the
        // sub-cost line. Income / transfers pass through.
        let cleaned = CashFlowEngine.filterOutSubscriptionLinked(
            transactions: transactions,
            subscriptions: subscriptions,
            calendar: calendar
        )

        let buckets = CashFlowEngine.monthlyBuckets(
            transactions: cleaned,
            months: bounded,
            now: now,
            calendar: calendar,
            accountsById: accountsById,
            fxRates: fxRates,
            baseCode: baseCode
        )

        let nonEmpty = buckets.filter { $0.income > 0 || $0.expense > 0 }
        let sample = nonEmpty.count
        guard sample > 0 else {
            return .empty
        }

        let totalIncome = nonEmpty.reduce(Int64(0)) { $0 + $1.income }
        let totalExpense = nonEmpty.reduce(Int64(0)) { $0 + $1.expense }
        let avgIncome = totalIncome / Int64(sample)
        let avgExpense = totalExpense / Int64(sample)

        // Subscription cost — average monthly equivalent across active subs.
        let monthlySubs: Int64 = subscriptions
            .filter { $0.status == .active }
            .map { CashFlowEngine.normalizeToMonthly(amount: $0.amount, period: $0.billingPeriod) }
            .reduce(0, +)

        let net = avgIncome - avgExpense - monthlySubs
        let rate: Decimal? = avgIncome > 0
            ? Decimal(net) / Decimal(avgIncome)
            : nil

        return Snapshot(
            avgMonthlyIncome: avgIncome,
            avgMonthlyExpense: avgExpense,
            monthlySubscriptionCost: monthlySubs,
            avgMonthlyNet: net,
            savingsRate: rate,
            sampleMonths: sample,
            confidence: CashFlowEngine.confidence(for: sample)
        )
    }
}
