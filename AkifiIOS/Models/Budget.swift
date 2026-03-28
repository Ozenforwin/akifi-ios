import Foundation

struct Budget: Decodable, Identifiable, Sendable {
    let id: String
    let userId: String
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

    init(id: String, userId: String, accountIds: [String]? = nil, budgetType: String? = nil, amount: Int64, billingPeriod: BillingPeriod, categoryIds: [String]? = nil, customStartDate: String? = nil, customEndDate: String? = nil, rolloverEnabled: Bool = false, alertThresholds: [Int]? = nil, isActive: Bool = true, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.accountIds = accountIds
        self.budgetType = budgetType; self.amount = amount; self.billingPeriod = billingPeriod
        self.categoryIds = categoryIds; self.customStartDate = customStartDate
        self.customEndDate = customEndDate; self.rolloverEnabled = rolloverEnabled
        self.alertThresholds = alertThresholds; self.isActive = isActive
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        accountIds = try container.decodeIfPresent([String].self, forKey: .accountIds)
        budgetType = try container.decodeIfPresent(String.self, forKey: .budgetType)
        // Handle numeric amount from DB (rubles → kopecks)
        if let dbl = try? container.decode(Double.self, forKey: .amount) {
            amount = Int64((dbl * 100).rounded())
        } else if let str = try? container.decode(String.self, forKey: .amount),
                  let decimal = Decimal(string: str) {
            amount = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        } else {
            amount = 0
        }
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

    // Compatibility helpers for views that used old field names
    var name: String {
        switch billingPeriod {
        case .monthly: "Месячный бюджет"
        case .quarterly: "Квартальный бюджет"
        case .yearly: "Годовой бюджет"
        case .weekly: "Недельный бюджет"
        case .custom: "Произвольный бюджет"
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
        case .weekly: return "Неделя"
        case .monthly: return "Месяц"
        case .quarterly: return "Квартал"
        case .yearly: return "Год"
        case .custom: return "Свой период"
        }
    }
}

enum BudgetType: String, Codable, Sendable, CaseIterable {
    case hard
    case soft
    case goal

    var displayName: String {
        switch self {
        case .hard: return "Жёсткий"
        case .soft: return "Мягкий"
        case .goal: return "Цель"
        }
    }

    var description: String {
        switch self {
        case .hard: return "Строгий лимит расходов"
        case .soft: return "Предупреждение при превышении"
        case .goal: return "Цель накопления"
        }
    }
}
