import Foundation

/// The user-editable part of a `notification_settings` row — what
/// smart-notifications obeys. Loaded from the server (N5), never from a
/// per-device copy.
struct NotificationSettings: Codable, Equatable, Sendable {
    var enabled = true
    var budgetWarnings = true
    /// 50…100, step 5.
    var budgetWarningPercent = 80
    var weeklyPace = false
    var largeExpenses = true
    /// Main units of the display currency; 0 = automatic.
    var largeExpenseThreshold = 0
    var inactivity = false
    var savingsMilestones = true

    static let defaults = NotificationSettings()

    static let columns = "enabled,budget_warnings,budget_warning_percent,weekly_pace,large_expenses,large_expense_threshold,inactivity,savings_milestones"

    enum CodingKeys: String, CodingKey {
        case enabled
        case budgetWarnings = "budget_warnings"
        case budgetWarningPercent = "budget_warning_percent"
        case weeklyPace = "weekly_pace"
        case largeExpenses = "large_expenses"
        case largeExpenseThreshold = "large_expense_threshold"
        case inactivity
        case savingsMilestones = "savings_milestones"
    }

    init() {}

    /// Tolerant: a NULL / missing column keeps the default; numbers may
    /// arrive as integers or decimals.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings.defaults
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            guard let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil else { return fallback }
            return Int(value.rounded())
        }
        enabled = bool(.enabled, d.enabled)
        budgetWarnings = bool(.budgetWarnings, d.budgetWarnings)
        budgetWarningPercent = int(.budgetWarningPercent, d.budgetWarningPercent)
        weeklyPace = bool(.weeklyPace, d.weeklyPace)
        largeExpenses = bool(.largeExpenses, d.largeExpenses)
        largeExpenseThreshold = int(.largeExpenseThreshold, d.largeExpenseThreshold)
        inactivity = bool(.inactivity, d.inactivity)
        savingsMilestones = bool(.savingsMilestones, d.savingsMilestones)
    }

    /// Upsert body: the settings plus the owner.
    struct Row: Encodable, Sendable {
        let userId: String
        let settings: NotificationSettings

        func encode(to encoder: Encoder) throws {
            try settings.encode(to: encoder)
            var c = encoder.container(keyedBy: UserKey.self)
            try c.encode(userId, forKey: .userId)
        }

        private enum UserKey: String, CodingKey { case userId = "user_id" }
    }
}
