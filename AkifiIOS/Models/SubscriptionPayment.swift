import Foundation

/// A single recorded payment against a subscription.
///
/// Mirrors the `public.subscription_payments` Supabase table.
/// `amount` is stored in minor units (kopecks/cents) in-memory, decoded from
/// a `NUMERIC(18,2)` rubles/dollars column via `decodeKopecks`.
struct SubscriptionPayment: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let subscriptionId: String
    let amount: Int64
    let currency: String
    let paymentDate: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case subscriptionId = "subscription_id"
        case amount, currency
        case paymentDate = "payment_date"
        case createdAt = "created_at"
    }

    init(id: String, subscriptionId: String, amount: Int64, currency: String,
         paymentDate: String, createdAt: String? = nil) {
        self.id = id
        self.subscriptionId = subscriptionId
        self.amount = amount
        self.currency = currency
        self.paymentDate = paymentDate
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        amount = container.decodeKopecks(forKey: .amount)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "RUB"
        paymentDate = try container.decode(String.self, forKey: .paymentDate)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(Double(amount) / 100.0, forKey: .amount)
        try container.encode(currency, forKey: .currency)
        try container.encode(paymentDate, forKey: .paymentDate)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
