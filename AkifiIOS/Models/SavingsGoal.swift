import Foundation

struct SavingsGoal: Decodable, Identifiable, Sendable {
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

    init(id: String, userId: String, name: String, icon: String, color: String, targetAmount: Int64, currentAmount: Int64, currency: String? = nil, deadline: String? = nil, description: String? = nil, accountId: String? = nil, interestRate: Double? = nil, interestType: String? = nil, interestCompound: Bool? = nil, totalInterestEarned: Int64? = nil, monthlyTarget: Int64? = nil, reminderEnabled: Bool = false, reminderDay: Int? = nil, status: SavingsGoalStatus = .active, completedAt: String? = nil, priority: Int = 0, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.name = name; self.icon = icon
        self.color = color; self.targetAmount = targetAmount; self.currentAmount = currentAmount
        self.currency = currency; self.deadline = deadline; self.description = description
        self.accountId = accountId; self.interestRate = interestRate; self.interestType = interestType
        self.interestCompound = interestCompound; self.totalInterestEarned = totalInterestEarned
        self.monthlyTarget = monthlyTarget; self.reminderEnabled = reminderEnabled
        self.reminderDay = reminderDay; self.status = status; self.completedAt = completedAt
        self.priority = priority; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        targetAmount = container.decodeKopecks(forKey: .targetAmount)
        currentAmount = container.decodeKopecks(forKey: .currentAmount)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        deadline = try container.decodeIfPresent(String.self, forKey: .deadline)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        interestRate = try container.decodeIfPresent(Double.self, forKey: .interestRate)
        interestType = try container.decodeIfPresent(String.self, forKey: .interestType)
        interestCompound = try container.decodeIfPresent(Bool.self, forKey: .interestCompound)
        totalInterestEarned = container.decodeKopecksIfPresent(forKey: .totalInterestEarned)
        monthlyTarget = container.decodeKopecksIfPresent(forKey: .monthlyTarget)
        reminderEnabled = try container.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
        reminderDay = try container.decodeIfPresent(Int.self, forKey: .reminderDay)
        status = try container.decodeIfPresent(SavingsGoalStatus.self, forKey: .status) ?? .active
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

}

enum SavingsGoalStatus: String, Codable, Sendable {
    case active
    case completed
    case paused
    case archived
}

struct SavingsContribution: Decodable, Identifiable, Sendable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        goalId = try container.decode(String.self, forKey: .goalId)
        userId = try container.decode(String.self, forKey: .userId)
        amount = container.decodeKopecks(forKey: .amount)
        type = try container.decode(ContributionType.self, forKey: .type)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        transactionId = try container.decodeIfPresent(String.self, forKey: .transactionId)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

enum ContributionType: String, Codable, Sendable {
    case contribution
    case withdrawal
    case interest
}
