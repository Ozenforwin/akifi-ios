import Foundation

struct Budget: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var budgetName: String?
    var budgetDescription: String?
    var accountIds: [String]?
    var budgetType: String?
    var amount: Int64
    var billingPeriod: BillingPeriod
    var categoryIds: [String]?
    var customStartDate: String?
    var customEndDate: String?
    var rolloverEnabled: Bool
    var alertThresholds: [Int]?
    var isActive: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case budgetName = "name"
        case budgetDescription = "description"
        case accountIds = "account_ids"
        case budgetType = "budget_type"
        case amount
        case billingPeriod = "period_type"
        case categoryIds = "category_ids"
        case customStartDate = "custom_start_date"
        case customEndDate = "custom_end_date"
        case rolloverEnabled = "rollover_enabled"
        case alertThresholds = "alert_thresholds"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, budgetName: String? = nil, budgetDescription: String? = nil, accountIds: [String]? = nil, budgetType: String? = nil, amount: Int64, billingPeriod: BillingPeriod, categoryIds: [String]? = nil, customStartDate: String? = nil, customEndDate: String? = nil, rolloverEnabled: Bool = false, alertThresholds: [Int]? = nil, isActive: Bool = true, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.budgetName = budgetName; self.budgetDescription = budgetDescription
        self.accountIds = accountIds; self.budgetType = budgetType; self.amount = amount; self.billingPeriod = billingPeriod
        self.categoryIds = categoryIds; self.customStartDate = customStartDate
        self.customEndDate = customEndDate; self.rolloverEnabled = rolloverEnabled
        self.alertThresholds = alertThresholds; self.isActive = isActive
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        budgetName = try container.decodeIfPresent(String.self, forKey: .budgetName)
        budgetDescription = try container.decodeIfPresent(String.self, forKey: .budgetDescription)
        accountIds = try container.decodeIfPresent([String].self, forKey: .accountIds)
        budgetType = try container.decodeIfPresent(String.self, forKey: .budgetType)
        amount = container.decodeKopecks(forKey: .amount)
        billingPeriod = try container.decode(BillingPeriod.self, forKey: .billingPeriod)
        categoryIds = try container.decodeIfPresent([String].self, forKey: .categoryIds)
        customStartDate = try container.decodeIfPresent(String.self, forKey: .customStartDate)
        customEndDate = try container.decodeIfPresent(String.self, forKey: .customEndDate)
        rolloverEnabled = try container.decodeIfPresent(Bool.self, forKey: .rolloverEnabled) ?? false
        alertThresholds = try container.decodeIfPresent([Int].self, forKey: .alertThresholds)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(budgetName, forKey: .budgetName)
        try container.encodeIfPresent(budgetDescription, forKey: .budgetDescription)
        try container.encodeIfPresent(accountIds, forKey: .accountIds)
        try container.encodeIfPresent(budgetType, forKey: .budgetType)
        try container.encode(amount, forKey: .amount)
        try container.encode(billingPeriod, forKey: .billingPeriod)
        try container.encodeIfPresent(categoryIds, forKey: .categoryIds)
        try container.encodeIfPresent(customStartDate, forKey: .customStartDate)
        try container.encodeIfPresent(customEndDate, forKey: .customEndDate)
        try container.encode(rolloverEnabled, forKey: .rolloverEnabled)
        try container.encodeIfPresent(alertThresholds, forKey: .alertThresholds)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    var name: String {
        if let n = budgetName, !n.isEmpty { return n }
        switch billingPeriod {
        case .monthly: return String(localized: "budget.periodName.monthly")
        case .quarterly: return String(localized: "budget.periodName.quarterly")
        case .yearly: return String(localized: "budget.periodName.yearly")
        case .weekly: return String(localized: "budget.periodName.weekly")
        case .custom: return String(localized: "budget.periodName.custom")
        }
    }
    var categories: [String]? { categoryIds }
    var accountId: String? { accountIds?.first }
    var alertThreshold: Double? {
        guard let first = alertThresholds?.first else { return nil }
        return Double(first) / 100.0
    }

    var budgetTypeEnum: BudgetType {
        BudgetType(rawValue: budgetType ?? "hard") ?? .hard
    }
}

enum BillingPeriod: String, Codable, Sendable, CaseIterable {
    case weekly
    case monthly
    case quarterly
    case yearly
    case custom

    var displayName: String {
        switch self {
        case .weekly: return String(localized: "billingPeriod.weekly")
        case .monthly: return String(localized: "billingPeriod.monthly")
        case .quarterly: return String(localized: "billingPeriod.quarterly")
        case .yearly: return String(localized: "billingPeriod.yearly")
        case .custom: return String(localized: "billingPeriod.custom")
        }
    }
}

enum BudgetType: String, Codable, Sendable, CaseIterable {
    case hard
    case soft
    case goal

    var displayName: String {
        switch self {
        case .hard: return String(localized: "budgetType.hard")
        case .soft: return String(localized: "budgetType.soft")
        case .goal: return String(localized: "budgetType.goal")
        }
    }

    var description: String {
        switch self {
        case .hard: return String(localized: "budgetType.hard.description")
        case .soft: return String(localized: "budgetType.soft.description")
        case .goal: return String(localized: "budgetType.goal.description")
        }
    }
}
