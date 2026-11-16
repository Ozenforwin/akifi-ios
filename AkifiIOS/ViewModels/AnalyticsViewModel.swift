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

struct CashflowPoint: Identifiable, Sendable, Equatable {
    let label: String
    let income: Decimal
    let expense: Decimal

    /// Bucket labels are unique within one chart, so the label is a stable
    /// identity — a fresh `UUID()` per recompute made Charts rebuild every bar.
    var id: String { label }
}

extension AnalyticsPeriod {
    /// Cashflow bucketing for the period picker shared by the analytics
    /// panels: days for a day/week, weeks for a month, months beyond.
    init(_ period: WidgetPeriod) {
        switch period {
        case .day, .week: self = .week
        case .month: self = .month
        case .threeMonths: self = .quarter
        case .year: self = .year
        }
    }
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

    func totalIncome(from transactions: [Transaction], dataStore: DataStore) -> Decimal {
        transactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(Decimal.zero) { $0 + dataStore.amountInBaseDisplay($1) }
    }

    func totalExpense(from transactions: [Transaction], dataStore: DataStore) -> Decimal {
        transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(Decimal.zero) { $0 + dataStore.amountInBaseDisplay($1) }
    }

    /// "dd.MM" bucket label for week/month period modes.
    private static let dayLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "dd.MM"
        return df
    }()

    /// "MM.yy" bucket label for quarter/year period modes.
    private static let monthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "MM.yy"
        return df
    }()

    func cashflowData(from transactions: [Transaction], dataStore: DataStore) -> [CashflowPoint] {
        Self.cashflowData(from: transactions, period: selectedPeriod, dataStore: dataStore)
    }

    /// Buckets non-transfer income / expense by `period` (see
    /// `AnalyticsPeriod.init(_: WidgetPeriod)`), oldest bucket first.
    static func cashflowData(
        from transactions: [Transaction],
        period: AnalyticsPeriod,
        dataStore: DataStore
    ) -> [CashflowPoint] {
        let calendar = Calendar.current
        let dateFormatter = AppDateFormatters.isoDate
        // Keyed by the bucket's anchor DATE (not its label) so the output
        // can be sorted chronologically — dictionary order previously drove
        // the bar order and charts could render buckets shuffled.
        var grouped: [Date: (income: Decimal, expense: Decimal)] = [:]
        // A year of rows spans at most ~366 distinct days: parse and bucket
        // each day once instead of once per row.
        var bucketByDay: [String: Date?] = [:]

        let labelFormatter = period == .quarter || period == .year
            ? monthLabelFormatter
            : dayLabelFormatter

        for tx in transactions {
            guard !tx.isTransfer else { continue }
            let bucket: Date?
            if let cached = bucketByDay[tx.date] {
                bucket = cached
            } else {
                bucket = dateFormatter.date(from: tx.date).map { txDate in
                    switch period {
                    case .week:
                        return calendar.startOfDay(for: txDate)
                    case .month:
                        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: txDate))!
                    case .quarter, .year:
                        return calendar.date(from: calendar.dateComponents([.year, .month], from: txDate))!
                    }
                }
                bucketByDay[tx.date] = bucket
            }
            guard let bucket else { continue }

            var entry = grouped[bucket, default: (income: .zero, expense: .zero)]
            let amount = dataStore.amountInBaseDisplay(tx)
            if tx.type == .income {
                entry.income += amount
            } else if tx.type == .expense {
                entry.expense += amount
            }
            grouped[bucket] = entry
        }

        return grouped
            .sorted { $0.key < $1.key }
            .map { CashflowPoint(label: labelFormatter.string(from: $0.key), income: $0.value.income, expense: $0.value.expense) }
    }

    func categoryBreakdown(from transactions: [Transaction], categories: [Category], dataStore: DataStore) -> [CategorySpending] {
        let expenses = transactions.filter { $0.type == .expense && !$0.isTransfer }
        let totalExpense = expenses.reduce(Decimal.zero) { $0 + dataStore.amountInBaseDisplay($1) }
        guard totalExpense > 0 else { return [] }

        var byCategory: [String: Decimal] = [:]
        for tx in expenses {
            let catId = tx.categoryId ?? "uncategorized"
            byCategory[catId, default: .zero] += dataStore.amountInBaseDisplay(tx)
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
