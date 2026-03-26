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

    func createBudget(name: String, amount: Int64, period: BillingPeriod, categories: [String]?, accountId: String?, rollover: Bool, alertThreshold: Double?) async {
        do {
            let input = CreateBudgetInput(
                name: name,
                amount: amount,
                billing_period: period.rawValue,
                categories: categories,
                account_id: accountId,
                rollover_enabled: rollover,
                alert_threshold: alertThreshold
            )
            let budget = try await budgetRepo.create(input)
            budgets.insert(budget, at: 0)
        } catch {
            self.error = error.localizedDescription
        }
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
        case .monthly:
            periodLabelFormatter.dateFormat = "LLLL yyyy"
            return periodLabelFormatter.string(from: Date()).capitalized
        case .quarterly:
            let month = Calendar.current.component(.month, from: Date())
            let quarter = (month - 1) / 3 + 1
            return "\(quarter)-й квартал \(Calendar.current.component(.year, from: Date()))"
        case .yearly:
            return "\(Calendar.current.component(.year, from: Date())) год"
        }
    }
}
