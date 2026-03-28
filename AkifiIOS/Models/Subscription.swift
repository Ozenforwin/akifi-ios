import Foundation

struct SubscriptionTracker: Decodable, Identifiable, Sendable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        // Handle numeric amount from DB (e.g. "100.00") → kopecks
        // Handle numeric amount from DB (rubles → kopecks)
        if let dbl = try? container.decode(Double.self, forKey: .amount) {
            amount = Int64((dbl * 100).rounded())
        } else if let str = try? container.decode(String.self, forKey: .amount),
                  let decimal = Decimal(string: str) {
            amount = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        } else {
            amount = 0
        }
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        billingPeriod = try container.decode(BillingPeriod.self, forKey: .billingPeriod)
        startDate = try container.decode(String.self, forKey: .startDate)
        nextPaymentDate = try container.decodeIfPresent(String.self, forKey: .nextPaymentDate)
        iconColor = try container.decodeIfPresent(String.self, forKey: .iconColor)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}
