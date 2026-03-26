import Foundation

struct Profile: Codable, Identifiable, Sendable {
    let id: String
    var email: String?
    var fullName: String?
    var avatarUrl: String?
    var telegramUserId: String?
    var telegramChatId: String?
    var telegramLinkedAt: String?
    let updatedAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case telegramUserId = "telegram_user_id"
        case telegramChatId = "telegram_chat_id"
        case telegramLinkedAt = "telegram_linked_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
    }
}
