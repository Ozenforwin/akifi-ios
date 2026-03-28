import Foundation

enum SavingsStatus {
    case onTrack, behind, critical, completed, noDeadline

    var label: String {
        switch self {
        case .onTrack: return String(localized: "savings.status.onTrack")
        case .behind: return String(localized: "savings.status.behind")
        case .critical: return String(localized: "savings.status.critical")
        case .completed: return String(localized: "savings.status.completed")
        case .noDeadline: return String(localized: "savings.status.noDeadline")
        }
    }

    var color: String {
        switch self {
        case .onTrack: return "#22C55E"
        case .behind: return "#F59E0B"
        case .critical: return "#EF4444"
        case .completed: return "#22C55E"
        case .noDeadline: return "#6B7280"
        }
    }
}

@Observable @MainActor
final class SavingsViewModel {
    var goals: [SavingsGoal] = []
    var contributions: [String: [SavingsContribution]] = [:]
    var isLoading = false
    var error: String?
    var showForm = false

    private let repo = SavingsGoalRepository()

    private let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var activeGoals: [SavingsGoal] {
        goals.filter { $0.status == .active }
    }

    var completedGoals: [SavingsGoal] {
        goals.filter { $0.status == .completed }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            goals = try await repo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadContributions(for goalId: String) async {
        do {
            contributions[goalId] = try await repo.fetchContributions(goalId: goalId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createGoal(name: String, icon: String, color: String, targetAmount: Int64, deadline: String?, accountId: String?) async {
        do {
            let input = CreateSavingsGoalInput(
                name: name,
                icon: icon,
                color: color,
                target_amount: targetAmount,
                deadline: deadline,
                account_id: accountId,
                reminder_enabled: false,
                priority: goals.count
            )
            let goal = try await repo.create(input)
            goals.insert(goal, at: 0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addContribution(goalId: String, amount: Int64, type: ContributionType, note: String?) async {
        do {
            let input = CreateContributionInput(
                goal_id: goalId,
                amount: amount,
                type: type.rawValue,
                note: note
            )
            let contribution = try await repo.addContribution(input)

            // Also create linked transaction for money tracking
            let goal = goals.first { $0.id == goalId }
            let txType = type == .withdrawal ? "income" : "expense"
            let desc = "\(goal?.name ?? "Накопления"): \(type == .withdrawal ? "снятие" : "пополнение")\(note != nil ? " — \(note!)" : "")"
            let txInput = CreateTransactionInput(
                account_id: goal?.accountId,
                amount: Decimal(amount) / 100, // kopecks → rubles for DB
                type: txType,
                date: isoDateFormatter.string(from: Date()),
                description: desc,
                category_id: nil,
                merchant_name: nil,
                currency: nil
            )
            _ = try? await TransactionRepository().create(txInput)

            // Update local state
            var existing = contributions[goalId] ?? []
            existing.insert(contribution, at: 0)
            contributions[goalId] = existing

            // Reload goal from DB (trigger auto-updates current_amount)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Savings status based on pace
    func savingsStatus(for goal: SavingsGoal) -> SavingsStatus {
        guard goal.targetAmount > goal.currentAmount else { return .completed }
        guard let days = daysRemaining(for: goal), days > 0 else {
            if goal.deadline != nil { return .critical }
            return .noDeadline
        }
        let remaining = goal.targetAmount - goal.currentAmount
        let dailyNeeded = Double(remaining) / Double(days)

        // Check if on track based on contributions
        let contribs = contributions[goal.id] ?? []
        let goalAge = max(1, Calendar.current.dateComponents([.day], from: isoDateFormatter.date(from: goal.createdAt ?? "") ?? Date(), to: Date()).day ?? 1)
        let avgDaily = contribs.filter { $0.type == .contribution }.reduce(Int64(0)) { $0 + $1.amount }
        let avgDailyRate = Double(avgDaily) / Double(goalAge)

        if avgDailyRate >= dailyNeeded * 0.8 { return .onTrack }
        if avgDailyRate >= dailyNeeded * 0.4 { return .behind }
        return .critical
    }

    func deleteGoal(_ goal: SavingsGoal) async {
        do {
            try await repo.delete(id: goal.id)
            goals.removeAll { $0.id == goal.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func progress(for goal: SavingsGoal) -> Double {
        guard goal.targetAmount > 0 else { return 0 }
        return min(Double(goal.currentAmount) / Double(goal.targetAmount), 1.0)
    }

    func daysRemaining(for goal: SavingsGoal) -> Int? {
        guard let deadline = goal.deadline else { return nil }
        guard let date = isoDateFormatter.date(from: deadline) else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day
    }
}
