import Foundation

@Observable @MainActor
final class BudgetsViewModel {
    var budgets: [Budget] = []
    var isLoading = false
    var error: String?
    var showForm = false
    var editingBudget: Budget?

    private let budgetRepo = BudgetRepository()
    private let metricsStore: BudgetMetricsStore

    private var hasLoaded = false

    init(metricsStore: BudgetMetricsStore = .shared) {
        self.metricsStore = metricsStore
    }

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

    // MARK: - Server metrics (B1)

    /// Loads `get_budget_metrics` into the shared store — the numbers every
    /// member of a shared budget sees. No-op when nothing changed since the
    /// last successful fetch; offline keeps the last good answer (B5).
    func loadMetrics(dataStore: DataStore, force: Bool = false) async {
        await metricsStore.refresh(dataStore: dataStore, force: force)
    }

    /// Budgets with the metrics to show (server first, local fallback),
    /// sorted by criticality: overLimit, nearLimit, warning, onTrack, then
    /// by utilization.
    func sortedBudgets(dataStore: DataStore) -> [(budget: Budget, resolved: ResolvedBudgetMetrics)] {
        let resolved = metricsStore.resolved(for: dataStore)
        let items = dataStore.budgets.compactMap { budget in
            resolved[budget.id].map { (budget: budget, resolved: $0) }
        }
        return items.sorted { a, b in
            let pa = Self.priority(a.resolved.metrics.status)
            let pb = Self.priority(b.resolved.metrics.status)
            if pa != pb { return pa < pb }
            return a.resolved.metrics.utilization > b.resolved.metrics.utilization
        }
    }

    private static func priority(_ status: BudgetStatus) -> Int {
        switch status {
        case .overLimit: return 0
        case .nearLimit: return 1
        case .warning: return 2
        case .onTrack: return 3
        }
    }

    // MARK: - Period (delegates to BudgetMath)

    func currentPeriod(for budget: Budget) -> (start: Date, end: Date) {
        BudgetMath.currentPeriod(for: budget)
    }

    func spent(for budget: Budget, transactions: [Transaction], currencyContext: BudgetMath.CurrencyContext) -> Int64 {
        let period = currentPeriod(for: budget)
        return BudgetMath.spentAmount(
            budget: budget,
            transactions: transactions,
            period: period,
            currencyContext: currencyContext
        )
    }

    func progress(for budget: Budget, transactions: [Transaction], currencyContext: BudgetMath.CurrencyContext) -> Double {
        guard budget.amount > 0 else { return 0 }
        let spentAmount = spent(for: budget, transactions: transactions, currencyContext: currencyContext)
        return Double(spentAmount) / Double(budget.amount)
    }

    func remaining(for budget: Budget, transactions: [Transaction], currencyContext: BudgetMath.CurrencyContext) -> Int64 {
        let spentAmount = spent(for: budget, transactions: transactions, currencyContext: currencyContext)
        return budget.amount - spentAmount
    }

    func periodLabel(for budget: Budget) -> String {
        let period = currentPeriod(for: budget)
        return Self.periodLabel(start: period.start, end: period.end)
    }

    // MARK: - Window label (D4)

    private static func formatter(_ template: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale.current
        df.calendar = Calendar(identifier: .gregorian)
        df.setLocalizedDateFormatFromTemplate(template)
        return df
    }

    private static let dayMonth = formatter("d MMM")
    private static let dayMonthYear = formatter("d MMM yyyy")

    /// The window the numbers actually cover — «19 окт – 17 ноя», with years
    /// only when it isn't entirely in the current year. Replaces the old
    /// calendar-month title on a 30-day rolling budget (D4); the push uses
    /// the same window.
    static func periodLabel(start: Date, end: Date, now: Date = Date()) -> String {
        let cal = BudgetMath.calendar
        let year = cal.component(.year, from: now)
        let sameYear = cal.component(.year, from: start) == year && cal.component(.year, from: end) == year
        let df = sameYear ? dayMonth : dayMonthYear
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }
}
