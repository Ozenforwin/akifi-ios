import Foundation
import SwiftUI

/// Typed insights surfaced to the user across Home, notifications, and AI context.
///
/// Kept deterministic and client-side so insights appear instantly without a
/// network round-trip and can be regenerated locally at any time.
enum InsightEngine {

    // MARK: - Types

    enum Kind: String, Sendable {
        case expensesTrendUp
        case expensesTrendDown
        case monthMoreExpensive
        case bigSingleExpense
        case topCategoryHeavy
        case noTransactionsRecent
        case budgetWarning
        case subscriptionApproaching
        case savingsMilestone
        case subscriptionsEatBudget

        var color: Color {
            switch self {
            case .expensesTrendDown, .savingsMilestone: return Color.income
            case .expensesTrendUp, .budgetWarning, .subscriptionApproaching,
                 .noTransactionsRecent, .topCategoryHeavy, .subscriptionsEatBudget:
                return Color.warning
            case .monthMoreExpensive, .bigSingleExpense:
                return Color.expense
            }
        }

        var emoji: String {
            switch self {
            case .expensesTrendUp: return "📈"
            case .expensesTrendDown: return "📉"
            case .monthMoreExpensive: return "⚡️"
            case .bigSingleExpense: return "💸"
            case .topCategoryHeavy: return "🎯"
            case .noTransactionsRecent: return "😴"
            case .budgetWarning: return "🚨"
            case .subscriptionApproaching: return "🔔"
            case .savingsMilestone: return "🎉"
            case .subscriptionsEatBudget: return "🔁"
            }
        }
    }

    struct Insight: Identifiable, Sendable, Equatable {
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String

        var emoji: String { kind.emoji }
    }

    struct Input: Sendable {
        let transactions: [Transaction]
        let categories: [Category]
        let budgets: [Budget]
        let subscriptions: [SubscriptionTracker]
        /// Format an amount in the user's display currency (used for transactions,
        /// budgets, aggregates — anything in the user's chosen currency).
        let formatAmount: @Sendable (Int64) -> String
        /// Format an amount using a specific currency symbol. Used for subscription
        /// insights so a USD subscription (e.g. Claude $100) doesn't show as ₽100.
        /// Defaults to `formatAmount` when the caller doesn't supply a formatter.
        let formatAmountInCurrency: @Sendable (Int64, String?) -> String
        let now: Date
        /// ADR-001: needed to normalize multi-currency transactions into a
        /// single comparable number. `accountsById`/`fxRates`/`baseCode` are
        /// fed into `TransactionMath.amountInBase`. Pre-ADR-001 callers pass
        /// `[:]`/`[:]`/`"RUB"` which yields the legacy 1:1 behaviour.
        let accountsById: [String: Account]
        let fxRates: [String: Decimal]
        let baseCode: String

        init(
            transactions: [Transaction],
            categories: [Category],
            budgets: [Budget],
            subscriptions: [SubscriptionTracker],
            formatAmount: @escaping @Sendable (Int64) -> String,
            formatAmountInCurrency: (@Sendable (Int64, String?) -> String)? = nil,
            now: Date = Date(),
            accountsById: [String: Account] = [:],
            fxRates: [String: Decimal] = [:],
            baseCode: String = "RUB"
        ) {
            self.transactions = transactions
            self.categories = categories
            self.budgets = budgets
            self.subscriptions = subscriptions
            self.formatAmount = formatAmount
            self.formatAmountInCurrency = formatAmountInCurrency ?? { amount, _ in formatAmount(amount) }
            self.now = now
            self.accountsById = accountsById
            self.fxRates = fxRates
            self.baseCode = baseCode
        }

        func amountInBase(_ tx: Transaction) -> Int64 {
            TransactionMath.amountInBase(tx, accountsById: accountsById, fxRates: fxRates, baseCode: baseCode)
        }
    }

    // MARK: - Entry point

    static func generate(_ input: Input, calendar: Calendar = .current) -> [Insight] {
        var out: [Insight] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = calendar
        df.timeZone = calendar.timeZone

        // --- Time windows ---
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: input.now)),
              let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart),
              let weekStart = calendar.date(byAdding: .day, value: -7, to: input.now),
              let prevWeekStart = calendar.date(byAdding: .day, value: -14, to: input.now) else {
            return out
        }

        // --- Aggregates ---
        var thisMonthExp: Int64 = 0
        var prevMonthExp: Int64 = 0
        var thisWeekExp: Int64 = 0
        var prevWeekExp: Int64 = 0
        var thisMonthCount = 0
        var biggestAmount: Int64 = 0
        var biggestCatId: String?
        var catSpending: [String: Int64] = [:]

        for tx in input.transactions {
            guard tx.type == .expense, !tx.isTransfer,
                  let d = df.date(from: tx.date) else { continue }
            let amount = input.amountInBase(tx)

            if d >= monthStart {
                thisMonthExp += amount
                thisMonthCount += 1
                if amount > biggestAmount {
                    biggestAmount = amount
                    biggestCatId = tx.categoryId
                }
                if let catId = tx.categoryId {
                    catSpending[catId, default: 0] += amount
                }
            } else if d >= prevMonthStart && d < monthStart {
                prevMonthExp += amount
            }

            if d >= weekStart {
                thisWeekExp += amount
            } else if d >= prevWeekStart && d < weekStart {
                prevWeekExp += amount
            }
        }

        // 1. Weekly trend
        if prevWeekExp > 0 && thisWeekExp > 0 {
            let changePct = Double(thisWeekExp - prevWeekExp) / Double(prevWeekExp) * 100
            if changePct > 15 {
                let pct = Int(changePct)
                out.append(Insight(
                    id: "weekly-up",
                    kind: .expensesTrendUp,
                    title: String(localized: "insight.expensesGrowing"),
                    subtitle: String(localized: "insight.expensesGrowing.detail.\(pct)")
                ))
            } else if changePct < -15 {
                let pct = Int(abs(changePct))
                out.append(Insight(
                    id: "weekly-down",
                    kind: .expensesTrendDown,
                    title: String(localized: "insight.expensesDecreasing"),
                    subtitle: String(localized: "insight.expensesDecreasing.detail.\(pct)")
                ))
            }
        }

        // 2. Monthly comparison
        if prevMonthExp > 0 && thisMonthExp > 0 {
            let changePct = Double(thisMonthExp - prevMonthExp) / Double(prevMonthExp) * 100
            if changePct > 20 {
                let thisFormatted = input.formatAmount(thisMonthExp)
                let prevFormatted = input.formatAmount(prevMonthExp)
                out.append(Insight(
                    id: "month-compare",
                    kind: .monthMoreExpensive,
                    title: String(localized: "insight.monthMoreExpensive"),
                    subtitle: String(localized: "insight.monthMoreExpensive.detail.\(thisFormatted).\(prevFormatted)")
                ))
            }
        }

        // 3. Big single expense (>3× monthly average)
        if thisMonthCount >= 3 && biggestAmount > 0 {
            let avg = thisMonthExp / Int64(thisMonthCount)
            if biggestAmount > avg * 3 {
                let catName = biggestCatId.flatMap { id in input.categories.first { $0.id == id }?.name } ?? String(localized: "insight.other")
                let pct = thisMonthExp > 0 ? Int(Double(biggestAmount) / Double(thisMonthExp) * 100) : 0
                out.append(Insight(
                    id: "big-expense",
                    kind: .bigSingleExpense,
                    title: String(localized: "insight.bigExpense.\(catName)"),
                    subtitle: String(localized: "insight.bigExpense.detail.\(pct)")
                ))
            }
        }

        // 4. Top category eating budget (≥40%)
        if let topCat = catSpending.max(by: { $0.value < $1.value }),
           thisMonthExp > 0 {
            let pct = Int(Double(topCat.value) / Double(thisMonthExp) * 100)
            if pct >= 40 {
                let catName = input.categories.first { $0.id == topCat.key }?.name ?? String(localized: "insight.category")
                out.append(Insight(
                    id: "top-cat-\(topCat.key)",
                    kind: .topCategoryHeavy,
                    title: String(localized: "insight.topCategory.\(catName).\(pct)"),
                    subtitle: String(localized: "insight.topCategory.detail")
                ))
            }
        }

        // 5. Budget warning — any budget past 85% utilization with days remaining
        for budget in input.budgets where budget.isActive {
            let metrics = BudgetMath.compute(budget: budget, transactions: input.transactions, subscriptions: input.subscriptions)
            if metrics.utilization >= 85 && metrics.remainingDays > 0 {
                out.append(Insight(
                    id: "budget-\(budget.id)",
                    kind: .budgetWarning,
                    title: String(localized: "insight.budgetWarning.\(budget.name).\(metrics.utilization)"),
                    subtitle: String(localized: "insight.budgetWarning.detail.\(metrics.remainingDays)")
                ))
            }
        }

        // 6. Subscription approaching (≤3 days)
        for sub in input.subscriptions where sub.status == .active {
            let days = sub.daysRemaining
            if days <= 3 && days >= 0 {
                out.append(Insight(
                    id: "sub-\(sub.id)",
                    kind: .subscriptionApproaching,
                    title: String(localized: "insight.subscription.\(sub.serviceName)"),
                    subtitle: days == 0
                        ? String(localized: "insight.subscription.today.\(input.formatAmountInCurrency(sub.amount, sub.currency))")
                        : String(localized: "insight.subscription.inDays.\(days).\(input.formatAmountInCurrency(sub.amount, sub.currency))")
                ))
            }
        }

        // 7. Subscriptions eat > 30% of any monthly budget
        for budget in input.budgets where budget.isActive && budget.billingPeriod == .monthly {
            let committed = BudgetMath.subscriptionCommitted(budget: budget, subscriptions: input.subscriptions)
            guard budget.amount > 0, committed > 0 else { continue }
            let pct = Int(Double(committed) / Double(budget.amount) * 100)
            if pct > 30 {
                out.append(Insight(
                    id: "subs-budget-\(budget.id)",
                    kind: .subscriptionsEatBudget,
                    title: String(localized: "insight.subscriptionsEatBudget.\(budget.name).\(pct)"),
                    subtitle: String(localized: "insight.subscriptionsEatBudget.detail.\(input.formatAmount(committed))")
                ))
            }
        }

        // 8. No transactions recently
        let noTxDays = daysSinceLastTransaction(transactions: input.transactions, df: df, now: input.now, calendar: calendar)
        if noTxDays >= 3 {
            out.append(Insight(
                id: "no-tx",
                kind: .noTransactionsRecent,
                title: String(localized: "insight.noTransactions.\(noTxDays)"),
                subtitle: String(localized: "insight.noTransactions.detail")
            ))
        }

        return out
    }

    // MARK: - Weekly Digest

    /// Compact weekly digest for a push notification.
    static func weeklyDigest(_ input: Input, calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = calendar
        df.timeZone = calendar.timeZone

        guard let weekStart = calendar.date(byAdding: .day, value: -7, to: input.now) else {
            return String(localized: "insight.weeklyDigest.empty")
        }

        var income: Int64 = 0
        var expense: Int64 = 0
        var count = 0
        for tx in input.transactions {
            guard !tx.isTransfer, let d = df.date(from: tx.date), d >= weekStart else { continue }
            let amount = input.amountInBase(tx)
            switch tx.type {
            case .income: income += amount
            case .expense: expense += amount; count += 1
            case .transfer: continue
            }
        }

        if count == 0 {
            return String(localized: "insight.weeklyDigest.empty")
        }

        let net = income - expense
        let incomeFmt = input.formatAmount(income)
        let expenseFmt = input.formatAmount(expense)
        let netFmt = input.formatAmount(abs(net))
        let netMarker = net >= 0 ? "+" : "−"
        return String(localized: "insight.weeklyDigest.\(count).\(incomeFmt).\(expenseFmt).\(netMarker).\(netFmt)")
    }

    // MARK: - Helpers

    private static func daysSinceLastTransaction(transactions: [Transaction], df: DateFormatter, now: Date, calendar: Calendar) -> Int {
        guard let latest = transactions.compactMap({ df.date(from: $0.date) }).max() else { return 0 }
        return calendar.dateComponents([.day], from: latest, to: now).day ?? 0
    }
}
