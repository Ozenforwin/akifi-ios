import Foundation

struct NotificationSettings: Codable, Sendable {
    var enabled: Bool
    var budgetWarnings: Bool
    var largeExpenses: Bool
    var inactivity: Bool
    var savingsMilestones: Bool
    var weeklyPace: Bool
    var largeExpenseThreshold: Int64?
    var budgetWarningPercent: Double?

    enum CodingKeys: String, CodingKey {
        case enabled
        case budgetWarnings = "budget_warnings"
        case largeExpenses = "large_expenses"
        case inactivity
        case savingsMilestones = "savings_milestones"
        case weeklyPace = "weekly_pace"
        case largeExpenseThreshold = "large_expense_threshold"
        case budgetWarningPercent = "budget_warning_percent"
    }
}
