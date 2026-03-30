import Foundation

@Observable @MainActor
final class ReportsViewModel {

    // MARK: - State

    var selectedMonth: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }()
    var selectedType: CategoryType = .expense
    var selectedAccountId: String?

    // MARK: - Private formatters

    private static let txDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "LLLL yyyy 'г.'"
        return df
    }()

    private static let shortMonthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "LLL yyyy"
        return df
    }()

    // MARK: - Computed: filtered transactions

    func monthTransactions(from all: [Transaction]) -> [Transaction] {
        let calendar = Calendar.current
        let monthStart = calendar.dateComponents([.year, .month], from: selectedMonth)

        return all.filter { tx in
            if let accountId = selectedAccountId, tx.accountId != accountId { return false }
            guard let txDate = Self.txDateFormatter.date(from: tx.date) else { return false }
            let txComponents = calendar.dateComponents([.year, .month], from: txDate)
            return txComponents.year == monthStart.year && txComponents.month == monthStart.month
        }
    }

    // MARK: - Computed: totals

    func monthIncome(from transactions: [Transaction]) -> Int64 {
        transactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    func monthExpense(from transactions: [Transaction]) -> Int64 {
        transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    func monthCashflow(from transactions: [Transaction]) -> Int64 {
        monthIncome(from: transactions) - monthExpense(from: transactions)
    }

    // MARK: - Computed: category breakdown

    struct CategoryBreakdownItem: Identifiable, Sendable {
        var id: String { category.id }
        let category: Category
        let amount: Int64
        let percentage: Double
        let txCount: Int
    }

    func categoryBreakdown(
        from transactions: [Transaction],
        categories: [Category]
    ) -> [CategoryBreakdownItem] {
        let filtered = transactions.filter { tx in
            !tx.isTransfer && (
                (selectedType == .expense && tx.type == .expense) ||
                (selectedType == .income && tx.type == .income)
            )
        }

        let total = filtered.reduce(Int64(0)) { $0 + $1.amount }
        guard total > 0 else { return [] }

        // Group by categoryId
        var byCategoryAmount: [String: Int64] = [:]
        var byCategoryCount: [String: Int] = [:]

        for tx in filtered {
            let catId = tx.categoryId ?? "uncategorized"
            byCategoryAmount[catId, default: 0] += tx.amount
            byCategoryCount[catId, default: 0] += 1
        }

        let fallbackCategory = Category(
            id: "uncategorized",
            userId: "",
            accountId: nil,
            name: "Без категории",
            icon: "💰",
            color: "#94A3B8",
            type: selectedType,
            isActive: true,
            createdAt: nil
        )

        return byCategoryAmount.compactMap { catId, amount in
            let cat = categories.first { $0.id == catId } ?? fallbackCategory
            let percentage = Double(amount) / Double(total) * 100.0
            let count = byCategoryCount[catId, default: 0]
            return CategoryBreakdownItem(
                category: cat,
                amount: amount,
                percentage: percentage,
                txCount: count
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: - Computed: daily balance trend

    struct DailyBalancePoint: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let balance: Double
    }

    func dailyBalanceTrend(from transactions: [Transaction]) -> [DailyBalancePoint] {
        let calendar = Calendar.current

        let comps = calendar.dateComponents([.year, .month], from: selectedMonth)
        guard let monthStart = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }

        // Build a dict: day-of-month -> net amount (income minus expense) in kopecks
        var dailyNet: [Int: Int64] = [:]

        for tx in transactions {
            guard !tx.isTransfer else { continue }
            guard let txDate = Self.txDateFormatter.date(from: tx.date) else { continue }
            let day = calendar.component(.day, from: txDate)

            let signed: Int64 = tx.type == .income ? tx.amount : -tx.amount
            dailyNet[day, default: 0] += signed
        }

        // Accumulate into cumulative balance
        var cumulative: Double = 0
        var result: [DailyBalancePoint] = []

        for day in range {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let net = dailyNet[day, default: 0]
            cumulative += Double(net) / 100.0
            result.append(DailyBalancePoint(date: date, balance: cumulative))
        }

        return result
    }

    // MARK: - Months list

    var months: [Date] {
        let calendar = Calendar.current
        let now = Date()
        let currentComps = calendar.dateComponents([.year, .month], from: now)
        guard let currentMonthStart = calendar.date(from: currentComps) else { return [] }

        return (0..<12).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonthStart)
        }
    }

    // MARK: - Labels

    func monthLabel(_ date: Date) -> String {
        Self.monthLabelFormatter.string(from: date).capitalizedFirstLetter
    }

    func shortMonthLabel(_ date: Date) -> String {
        Self.shortMonthLabelFormatter.string(from: date).capitalizedFirstLetter
    }

    // MARK: - Helpers

    private static func startOfCurrentMonth() -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: comps) ?? Date()
    }
}

// MARK: - String helper

private extension String {
    var capitalizedFirstLetter: String {
        guard let first = self.first else { return self }
        return String(first).uppercased() + self.dropFirst()
    }
}
