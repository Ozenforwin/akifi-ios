import Foundation

struct Achievement: Codable, Identifiable, Sendable {
    let id: String
    let key: String
    var category: AchievementCategory
    var nameRu: String
    var nameEn: String
    var descriptionRu: String?
    var descriptionEn: String?
    var icon: String
    var tier: AchievementTier
    var points: Int
    var conditionType: String
    var conditionValue: Int?
    var triggerType: String?
    var isSecret: Bool
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, key, category
        case nameRu = "name_ru"
        case nameEn = "name_en"
        case descriptionRu = "description_ru"
        case descriptionEn = "description_en"
        case icon, tier, points
        case conditionType = "condition_type"
        case conditionValue = "condition_value"
        case triggerType = "trigger_type"
        case isSecret = "is_secret"
        case sortOrder = "sort_order"
    }
}

enum AchievementCategory: String, Codable, Sendable {
    case gettingStarted = "getting_started"
    case streaks, transactions, budgets, savings, ai, advanced, wisdom, secret
}

enum AchievementTier: String, Codable, Sendable {
    case bronze, silver, gold, diamond
}

struct UserAchievement: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    let achievementId: String
    let unlockedAt: String?
    var progress: Double
    var notified: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case achievementId = "achievement_id"
        case unlockedAt = "unlocked_at"
        case progress, notified
    }
}
