import Foundation

/// Domain service that projects cash flow forward based on historical patterns,
/// regular subscriptions, and the user's current total balance.
///
/// Approach:
/// 1. Analyze the last N months of transactions to estimate typical monthly
///    income and expenses (excluding transfers).
/// 2. Layer in committed subscriptions, normalized to a monthly rate.
/// 3. Compute end-of-month balance for the next 1-6 months, with a
///    confidence band based on historical variance.
///
/// This is deliberately deterministic and fully client-side — no LLM call.
enum CashFlowEngine {

    // MARK: - Models

    struct MonthPoint: Sendable, Equatable {
        let date: Date              // end-of-month date (anchor)
        let projectedBalance: Int64 // expected end-of-month balance in minor units
        let optimistic: Int64       // +1 sigma
        let pessimistic: Int64      // -1 sigma
        let expectedIncome: Int64
        let expectedExpense: Int64
        let subscriptionCost: Int64
    }

    struct Forecast: Sendable, Equatable {
        let startingBalance: Int64
        let avgMonthlyIncome: Int64
        let avgMonthlyExpense: Int64
        let monthlySubscriptionCost: Int64
        let sampleMonths: Int          // how many months of history we used
        let confidence: Confidence
        let points: [MonthPoint]

        /// Net monthly savings rate (income - expense - subscriptions).
        var netMonthly: Int64 {
            avgMonthlyIncome - avgMonthlyExpense - monthlySubscriptionCost
        }
    }

    enum Confidence: String, Sendable {
        case low       // <2 months of history
        case medium    // 2-3 months
        case high      // 4+ months

        var localizedName: String {
            switch self {
            case .low: return String(localized: "forecast.confidence.low")
            case .medium: return String(localized: "forecast.confidence.medium")
            case .high: return String(localized: "forecast.confidence.high")
            }
        }
    }

    // MARK: - Public API

    /// Compute a forward forecast.
    ///
    /// - Parameters:
    ///   - startingBalance: current aggregated balance across accounts in minor units
    ///   - transactions: history (all accounts, all types)
    ///   - subscriptions: active committed subscriptions
    ///   - monthsAhead: horizon length (1-12)
    ///   - historyMonths: how many past months to analyze (default 3)
    ///   - now: injectable for deterministic tests
    static func forecast(
        startingBalance: Int64,
        transactions: [Transaction],
        subscriptions: [SubscriptionTracker],
        monthsAhead: Int = 3,
        historyMonths: Int = 3,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Forecast {
        let horizon = max(1, min(12, monthsAhead))
        let history = max(1, min(12, historyMonths))

        // 1. Build monthly buckets for income/expense.
        let buckets = monthlyBuckets(transactions: transactions, months: history, now: now, calendar: calendar)
        let sampleMonths = buckets.count

        let totalIncome = buckets.reduce(Int64(0)) { $0 + $1.income }
        let totalExpense = buckets.reduce(Int64(0)) { $0 + $1.expense }
        let avgIncome = sampleMonths > 0 ? totalIncome / Int64(sampleMonths) : 0
        let avgExpense = sampleMonths > 0 ? totalExpense / Int64(sampleMonths) : 0

        // 2. Monthly subscription cost (active only, normalized to monthly).
        let monthlySubs = subscriptions
            .filter { $0.status == .active }
            .reduce(Int64(0)) { acc, sub in
                acc + normalizeToMonthly(amount: sub.amount, period: sub.billingPeriod)
            }

        // 3. Variance on expense for confidence band.
        let expenseVariance = variance(
            values: buckets.map(\.expense),
            mean: avgExpense
        )
        let expenseStdDev = Int64(Double(expenseVariance).squareRoot())

        // 4. Build forward month points.
        var points: [MonthPoint] = []
        var runningBalance = startingBalance
        var runningOptimistic = startingBalance
        var runningPessimistic = startingBalance

        for i in 1...horizon {
            guard let anchor = calendar.date(byAdding: .month, value: i, to: now),
                  let endOfMonth = endOfMonth(for: anchor, calendar: calendar) else { continue }

            let netMonthly = avgIncome - avgExpense - monthlySubs
            runningBalance += netMonthly
            runningOptimistic += (avgIncome - (avgExpense - expenseStdDev) - monthlySubs)
            runningPessimistic += (avgIncome - (avgExpense + expenseStdDev) - monthlySubs)

            points.append(MonthPoint(
                date: endOfMonth,
                projectedBalance: runningBalance,
                optimistic: runningOptimistic,
                pessimistic: runningPessimistic,
                expectedIncome: avgIncome,
                expectedExpense: avgExpense,
                subscriptionCost: monthlySubs
            ))
        }

        return Forecast(
            startingBalance: startingBalance,
            avgMonthlyIncome: avgIncome,
            avgMonthlyExpense: avgExpense,
            monthlySubscriptionCost: monthlySubs,
            sampleMonths: sampleMonths,
            confidence: confidence(for: sampleMonths),
            points: points
        )
    }

    // MARK: - Helpers

    struct MonthlyBucket: Sendable, Equatable {
        let income: Int64
        let expense: Int64
    }

    static func monthlyBuckets(
        transactions: [Transaction],
        months: Int,
        now: Date,
        calendar: Calendar
    ) -> [MonthlyBucket] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = calendar
        df.timeZone = calendar.timeZone

        var buckets: [String: MonthlyBucket] = [:]
        // Seed keys for the last `months` months so missing months count as zero.
        var cutoffMonths: [String] = []
        for i in 1...months {
            guard let monthDate = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: monthDate)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            buckets[key] = MonthlyBucket(income: 0, expense: 0)
            cutoffMonths.append(key)
        }

        for tx in transactions {
            guard !tx.isTransfer, let d = df.date(from: tx.date) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: d)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            guard buckets[key] != nil else { continue }
            let current = buckets[key] ?? MonthlyBucket(income: 0, expense: 0)
            switch tx.type {
            case .income:
                buckets[key] = MonthlyBucket(income: current.income + tx.amount, expense: current.expense)
            case .expense:
                buckets[key] = MonthlyBucket(income: current.income, expense: current.expense + tx.amount)
            case .transfer:
                continue
            }
        }

        return cutoffMonths.compactMap { buckets[$0] }
    }

    static func normalizeToMonthly(amount: Int64, period: BillingPeriod) -> Int64 {
        switch period {
        case .weekly: return Int64(Double(amount) * 52.0 / 12.0)
        case .monthly: return amount
        case .quarterly: return amount / 3
        case .yearly: return amount / 12
        case .custom: return amount
        }
    }

    static func variance(values: [Int64], mean: Int64) -> Int64 {
        guard values.count > 1 else { return 0 }
        let sumSq = values.reduce(0.0) { acc, v in
            let diff = Double(v - mean)
            return acc + diff * diff
        }
        return Int64(sumSq / Double(values.count - 1))
    }

    static func confidence(for sampleMonths: Int) -> Confidence {
        if sampleMonths >= 4 { return .high }
        if sampleMonths >= 2 { return .medium }
        return .low
    }

    static func endOfMonth(for date: Date, calendar: Calendar) -> Date? {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        return calendar.date(byAdding: .second, value: -1, to: interval.end)
    }
}
