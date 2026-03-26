import Foundation

struct UserSubscription: Codable, Sendable {
    let userId: String
    var status: SubscriptionStatus
    var tier: SubscriptionTier
    var currentPeriodStart: String?
    var currentPeriodEnd: String?
    var cancelAtPeriodEnd: Bool?
    var provider: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status, tier
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case provider
    }
}

enum SubscriptionStatus: String, Codable, Sendable {
    case active
    case trialing
    case pastDue = "past_due"
    case canceled
    case expired
}

enum SubscriptionTier: String, Codable, Sendable {
    case free
    case pro
    case lifetime
}
