import Foundation

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

            // Update local contributions
            var existing = contributions[goalId] ?? []
            existing.insert(contribution, at: 0)
            contributions[goalId] = existing

            // Update goal's current amount locally
            if let index = goals.firstIndex(where: { $0.id == goalId }) {
                switch type {
                case .contribution, .interest:
                    goals[index].currentAmount += amount
                case .withdrawal:
                    goals[index].currentAmount -= amount
                }
                // Check completion
                if goals[index].currentAmount >= goals[index].targetAmount {
                    goals[index].status = .completed
                    try await repo.update(id: goalId, UpdateSavingsGoalInput(
                        name: nil, target_amount: nil,
                        current_amount: goals[index].currentAmount,
                        status: "completed", deadline: nil
                    ))
                } else {
                    try await repo.update(id: goalId, UpdateSavingsGoalInput(
                        name: nil, target_amount: nil,
                        current_amount: goals[index].currentAmount,
                        status: nil, deadline: nil
                    ))
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
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
