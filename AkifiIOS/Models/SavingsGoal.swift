import Foundation

struct SavingsGoal: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var name: String
    var icon: String
    var color: String
    var targetAmount: Int64
    var currentAmount: Int64
    var currency: String?
    var deadline: String?
    var description: String?
    var accountId: String?
    var interestRate: Double?
    var interestType: String?
    var interestCompound: Bool?
    var totalInterestEarned: Int64?
    var monthlyTarget: Int64?
    var reminderEnabled: Bool
    var reminderDay: Int?
    var status: SavingsGoalStatus
    var completedAt: String?
    var priority: Int
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, icon, color
        case targetAmount = "target_amount"
        case currentAmount = "current_amount"
        case currency, deadline, description
        case accountId = "account_id"
        case interestRate = "interest_rate"
        case interestType = "interest_type"
        case interestCompound = "interest_compound"
        case totalInterestEarned = "total_interest_earned"
        case monthlyTarget = "monthly_target"
        case reminderEnabled = "reminder_enabled"
        case reminderDay = "reminder_day"
        case status
        case completedAt = "completed_at"
        case priority
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum SavingsGoalStatus: String, Codable, Sendable {
    case active
    case completed
    case paused
    case archived
}

struct SavingsContribution: Codable, Identifiable, Sendable {
    let id: String
    let goalId: String
    let userId: String
    var amount: Int64
    var type: ContributionType
    var note: String?
    var transactionId: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case goalId = "goal_id"
        case userId = "user_id"
        case amount, type, note
        case transactionId = "transaction_id"
        case createdAt = "created_at"
    }
}

enum ContributionType: String, Codable, Sendable {
    case contribution
    case withdrawal
    case interest
}
