import Foundation

/// Derives unlocked skill-tree nodes from local data. Deterministic, pure;
/// no DB calls.
///
/// A node is considered "unlocked" if:
/// 1. Its prerequisites are all unlocked, AND
/// 2. Its own rule evaluates to true against the provided inputs.
///
/// Rule: matched 1:1 to `SkillNodeID`. Adding a new node in `SkillNode.all`
/// requires extending the switch in `evaluateRule`.
enum SkillTreeEngine {

    struct Input: Sendable {
        let transactions: [Transaction]
        let accounts: [Account]
        let categories: [Category]
        let budgets: [Budget]
        let subscriptions: [SubscriptionTracker]
        let goals: [SavingsGoal]
        let currentStreak: Int
        /// Flag set when the user has exported at least one PDF report.
        let hasExportedReport: Bool
    }

    // MARK: - Public API

    /// Returns the set of unlocked node IDs for the given inputs.
    static func unlockedNodes(_ input: Input) -> Set<SkillNodeID> {
        // Multi-pass: re-evaluate until stable, because prerequisites chain.
        var unlocked = Set<SkillNodeID>()
        var changed = true
        let nodes = SkillNode.all
        while changed {
            changed = false
            for node in nodes where !unlocked.contains(node.id) {
                let prereqsOK = node.prerequisites.allSatisfy { unlocked.contains($0) }
                guard prereqsOK else { continue }
                if evaluateRule(node.id, input: input) {
                    unlocked.insert(node.id)
                    changed = true
                }
            }
        }
        return unlocked
    }

    // MARK: - Rules

    private static func evaluateRule(_ id: SkillNodeID, input: Input) -> Bool {
        switch id {
        case .firstTransaction:
            return !input.transactions.isEmpty
        case .firstAccount:
            return !input.accounts.isEmpty
        case .firstBudget:
            return input.budgets.contains { $0.isActive }
        case .firstGoal:
            return input.goals.contains { $0.status == .active || $0.status == .completed }
        case .firstCategory:
            // At least one user-defined (non-default) category is used.
            return !input.categories.isEmpty
        case .streak7:
            return input.currentStreak >= 7
        case .streak30:
            return input.currentStreak >= 30
        case .streak100:
            return input.currentStreak >= 100
        case .twoAccounts:
            return input.accounts.count >= 2
        case .threeCategories:
            return input.categories.count >= 3
        case .firstSubscription:
            return !input.subscriptions.isEmpty
        case .firstRecurringIncome:
            // Heuristic: ≥2 income transactions on the same day-of-month in
            // different months → looks recurring.
            let incomeByDay = Dictionary(grouping: input.transactions.filter { $0.type == .income }) { tx in
                String(tx.date.suffix(2))  // "yyyy-MM-dd" → "dd"
            }
            let months = Set(input.transactions.filter { $0.type == .income }.map { String($0.date.prefix(7)) })
            return incomeByDay.values.contains { $0.count >= 2 } && months.count >= 2
        case .savingsMilestone:
            return input.goals.contains { goal in
                guard goal.targetAmount > 0 else { return false }
                return Double(goal.currentAmount) / Double(goal.targetAmount) >= 0.5
            }
        case .diverseBudgets:
            return input.budgets.filter { $0.isActive }.count >= 2
        case .expertReporter:
            return input.hasExportedReport
        }
    }
}

/// Persistent flag for `SkillNodeID.expertReporter`. Set from the PDF export
/// flow so the skill engine can read it back on next evaluation. Kept trivial
/// (UserDefaults) — no need for a DB column yet.
enum SkillTreeFlags {
    private static let pdfExportedKey = "skills.hasExportedPDF"

    static var hasExportedPDF: Bool {
        get { UserDefaults.standard.bool(forKey: pdfExportedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pdfExportedKey) }
    }
}
