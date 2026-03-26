import Foundation

struct AiConversation: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var title: String?
    var source: String?
    var isArchived: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, source
        case isArchived = "is_archived"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct AiMessage: Codable, Identifiable, Sendable {
    let id: String
    let conversationId: String
    let userId: String
    var role: MessageRole
    var content: String
    var intent: String?
    var period: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case userId = "user_id"
        case role, content, intent, period
        case createdAt = "created_at"
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}
