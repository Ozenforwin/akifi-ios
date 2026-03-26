import Foundation

struct Budget: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var accountId: String?
    var name: String
    var amount: Int64
    var currency: String?
    var billingPeriod: BillingPeriod
    var categories: [String]?
    var periodStart: String?
    var periodEnd: String?
    var rolloverEnabled: Bool
    var alertThreshold: Double?
    var thresholdType: String?
    var isActive: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case accountId = "account_id"
        case name, amount, currency
        case billingPeriod = "billing_period"
        case categories
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case rolloverEnabled = "rollover_enabled"
        case alertThreshold = "alert_threshold"
        case thresholdType = "threshold_type"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum BillingPeriod: String, Codable, Sendable {
    case monthly
    case quarterly
    case yearly
}
