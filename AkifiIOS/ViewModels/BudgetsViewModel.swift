import Foundation

@Observable @MainActor
final class BudgetsViewModel {
    var budgets: [Budget] = []
    var isLoading = false
    var error: String?
    var showForm = false
    var editingBudget: Budget?

    private let budgetRepo = BudgetRepository()

    private let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private let periodLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        return df
    }()

    func load() async {
        isLoading = true
        error = nil
        do {
            budgets = try await budgetRepo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func reloadBudgets() async {
        await load()
    }

    func deleteBudget(_ budget: Budget) async {
        do {
            try await budgetRepo.delete(id: budget.id)
            budgets.removeAll { $0.id == budget.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Period Calculations

    func currentPeriod(for budget: Budget) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()

        switch budget.billingPeriod {
        case .weekly:
            let weekday = calendar.component(.weekday, from: now)
            let daysToMonday = (weekday + 5) % 7
            let start = calendar.date(byAdding: .day, value: -daysToMonday, to: calendar.startOfDay(for: now))!
            let end = calendar.date(byAdding: .day, value: 6, to: start)! // Sunday
            return (start, end)
        case .monthly:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .quarterly:
            let month = calendar.component(.month, from: now)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: now)
            components.month = quarterStartMonth
            components.day = 1
            let start = calendar.date(from: components)!
            let end = calendar.date(byAdding: .month, value: 3, to: start)!
            return (start, end)
        case .yearly:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
            let end = calendar.date(byAdding: .year, value: 1, to: start)!
            return (start, end)
        case .custom:
            if let startStr = budget.customStartDate,
               let endStr = budget.customEndDate,
               let start = isoDateFormatter.date(from: startStr),
               let end = isoDateFormatter.date(from: endStr) {
                return (start, end)
            }
            // Fallback to monthly
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        }
    }

    func spent(for budget: Budget, transactions: [Transaction]) -> Int64 {
        let period = currentPeriod(for: budget)

        return transactions.filter { tx in
            guard tx.type == .expense else { return false }
            if let cats = budget.categories, !cats.isEmpty {
                guard let catId = tx.categoryId, cats.contains(catId) else { return false }
            }
            if let accountId = budget.accountId {
                guard tx.accountId == accountId else { return false }
            }
            guard let txDate = isoDateFormatter.date(from: tx.date) else { return false }
            return txDate >= period.start && txDate < period.end
        }.reduce(Int64(0)) { $0 + $1.amount }
    }

    func progress(for budget: Budget, transactions: [Transaction]) -> Double {
        guard budget.amount > 0 else { return 0 }
        let spentAmount = spent(for: budget, transactions: transactions)
        return Double(spentAmount) / Double(budget.amount)
    }

    func remaining(for budget: Budget, transactions: [Transaction]) -> Int64 {
        let spentAmount = spent(for: budget, transactions: transactions)
        return budget.amount - spentAmount
    }

    func periodLabel(for budget: Budget) -> String {
        switch budget.billingPeriod {
        case .weekly:
            let period = currentPeriod(for: budget)
            let df = DateFormatter()
            df.dateFormat = "d MMM"
            df.locale = Locale(identifier: "ru_RU")
            return "\(df.string(from: period.start)) – \(df.string(from: period.end))"
        case .monthly:
            periodLabelFormatter.dateFormat = "LLLL yyyy"
            return periodLabelFormatter.string(from: Date()).capitalized
        case .quarterly:
            let month = Calendar.current.component(.month, from: Date())
            let quarter = (month - 1) / 3 + 1
            return "\(quarter)-й квартал \(Calendar.current.component(.year, from: Date()))"
        case .yearly:
            return "\(Calendar.current.component(.year, from: Date())) год"
        case .custom:
            let period = currentPeriod(for: budget)
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy"
            df.locale = Locale(identifier: "ru_RU")
            return "\(df.string(from: period.start)) – \(df.string(from: period.end))"
        }
    }
}
