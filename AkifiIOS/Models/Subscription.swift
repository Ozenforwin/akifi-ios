import Foundation

struct SubscriptionTracker: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var serviceName: String
    var amount: Int64
    var currency: String?
    var billingPeriod: BillingPeriod
    var startDate: String
    var nextPaymentDate: String?
    var iconColor: String?
    var isActive: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case serviceName = "service_name"
        case amount, currency
        case billingPeriod = "billing_period"
        case startDate = "start_date"
        case nextPaymentDate = "next_payment_date"
        case iconColor = "icon_color"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
