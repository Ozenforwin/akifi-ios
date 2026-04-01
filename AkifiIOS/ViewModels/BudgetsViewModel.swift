import Foundation

@Observable @MainActor
final class BudgetsViewModel {
    var budgets: [Budget] = []
    var isLoading = false
    var error: String?
    var showForm = false
    var editingBudget: Budget?

    private let budgetRepo = BudgetRepository()

    private let periodLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        return df
    }()

    private var hasLoaded = false

    func load() async {
        guard !hasLoaded else { return }
        await forceLoad()
    }

    func reloadBudgets() async {
        await forceLoad()
    }

    private func forceLoad() async {
        isLoading = true
        error = nil
        do {
            budgets = try await budgetRepo.fetchAll()
            hasLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func deleteBudget(_ budget: Budget) async {
        do {
            try await budgetRepo.delete(id: budget.id)
            budgets.removeAll { $0.id == budget.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Period Calculations (delegates to BudgetMath)

    func currentPeriod(for budget: Budget) -> (start: Date, end: Date) {
        BudgetMath.currentPeriod(for: budget)
    }

    func spent(for budget: Budget, transactions: [Transaction]) -> Int64 {
        let period = currentPeriod(for: budget)
        return BudgetMath.spentAmount(budget: budget, transactions: transactions, period: period)
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
            periodLabelFormatter.dateFormat = "d MMM"
            return "\(periodLabelFormatter.string(from: period.start)) – \(periodLabelFormatter.string(from: period.end))"
        case .monthly:
            periodLabelFormatter.dateFormat = "LLLL yyyy"
            return periodLabelFormatter.string(from: Date()).capitalized
        case .quarterly:
            let month = Calendar.current.component(.month, from: Date())
            let quarter = (month - 1) / 3 + 1
            return String(localized: "budget.quarterLabel.\(quarter).\(Calendar.current.component(.year, from: Date()))")
        case .yearly:
            return String(Calendar.current.component(.year, from: Date()))
        case .custom:
            let period = currentPeriod(for: budget)
            periodLabelFormatter.dateFormat = "d MMM yyyy"
            return "\(periodLabelFormatter.string(from: period.start)) – \(periodLabelFormatter.string(from: period.end))"
        }
    }
}
