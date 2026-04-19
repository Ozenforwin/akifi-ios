import Foundation

enum AnalyticsPeriod: String, CaseIterable, Sendable {
    case week = "week"
    case month = "month"
    case quarter = "quarter"
    case year = "year"

    var displayName: String {
        switch self {
        case .week: String(localized: "analyticsPeriod.week")
        case .month: String(localized: "analyticsPeriod.month")
        case .quarter: String(localized: "analyticsPeriod.quarter")
        case .year: String(localized: "analyticsPeriod.year")
        }
    }
}

struct CashflowPoint: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let income: Decimal
    let expense: Decimal
}

struct CategorySpending: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let color: String
    let amount: Decimal
    let percentage: Double
}

@Observable @MainActor
final class AnalyticsViewModel {
    var selectedPeriod: AnalyticsPeriod = .month
    var selectedAccountId: String?

    private let dateFormatter = AppDateFormatters.isoDate

    func filteredTransactions(from all: [Transaction]) -> [Transaction] {
        let calendar = Calendar.current
        let now = Date()

        let startDate: Date
        switch selectedPeriod {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now)!
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now)!
        case .quarter:
            startDate = calendar.date(byAdding: .month, value: -3, to: now)!
        case .year:
            startDate = calendar.date(byAdding: .year, value: -1, to: now)!
        }

        return all.filter { tx in
            if let accountId = selectedAccountId, tx.accountId != accountId { return false }
            guard let txDate = dateFormatter.date(from: tx.date) else { return false }
            return txDate >= startDate
        }
    }

    func totalIncome(from transactions: [Transaction]) -> Decimal {
        transactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(Decimal.zero) { $0 + $1.amount.displayAmount }
    }

    func totalExpense(from transactions: [Transaction]) -> Decimal {
        transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(Decimal.zero) { $0 + $1.amount.displayAmount }
    }

    func cashflowData(from transactions: [Transaction]) -> [CashflowPoint] {
        let calendar = Calendar.current
        var grouped: [String: (income: Decimal, expense: Decimal)] = [:]

        let labelFormatter = DateFormatter()
        labelFormatter.locale = Locale.current

        let groupFormatter: DateFormatter
        switch selectedPeriod {
        case .week:
            labelFormatter.dateFormat = "dd.MM"
            groupFormatter = labelFormatter
        case .month:
            labelFormatter.dateFormat = "dd.MM"
            groupFormatter = DateFormatter()
            groupFormatter.dateFormat = "yyyy-MM-dd"
        case .quarter, .year:
            labelFormatter.dateFormat = "MM.yy"
            groupFormatter = DateFormatter()
            groupFormatter.dateFormat = "yyyy-MM"
        }

        for tx in transactions {
            guard !tx.isTransfer else { continue }
            guard let txDate = dateFormatter.date(from: tx.date) else { continue }

            let key: String
            switch selectedPeriod {
            case .week:
                key = labelFormatter.string(from: txDate)
            case .month:
                let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: txDate))!
                key = labelFormatter.string(from: weekStart)
            case .quarter, .year:
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: txDate))!
                key = labelFormatter.string(from: monthStart)
            }

            var entry = grouped[key, default: (income: .zero, expense: .zero)]
            if tx.type == .income {
                entry.income += tx.amountNative.displayAmount
            } else if tx.type == .expense {
                entry.expense += tx.amountNative.displayAmount
            }
            grouped[key] = entry
        }

        return grouped.map { CashflowPoint(label: $0.key, income: $0.value.income, expense: $0.value.expense) }
    }

    func categoryBreakdown(from transactions: [Transaction], categories: [Category]) -> [CategorySpending] {
        let expenses = transactions.filter { $0.type == .expense && !$0.isTransfer }
        let totalExpense = expenses.reduce(Decimal.zero) { $0 + $1.amountNative.displayAmount }
        guard totalExpense > 0 else { return [] }

        var byCategory: [String: Decimal] = [:]
        for tx in expenses {
            let catId = tx.categoryId ?? "uncategorized"
            byCategory[catId, default: .zero] += tx.amountNative.displayAmount
        }

        return byCategory.compactMap { catId, amount in
            let cat = categories.first { $0.id == catId }
            let percentage = Double(truncating: (amount / totalExpense * 100) as NSDecimalNumber)
            return CategorySpending(
                id: catId,
                name: cat?.name ?? String(localized: "category.uncategorized"),
                icon: cat?.icon ?? "💰",
                color: cat?.color ?? "#94A3B8",
                amount: amount,
                percentage: percentage
            )
        }
        .sorted { $0.amount > $1.amount }
    }
}
