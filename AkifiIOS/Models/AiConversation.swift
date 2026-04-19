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

/// Snapshot used by the "Continue last chat" welcome card.
struct ConversationPreview: Sendable {
    let conversation: AiConversation
    let lastAnswer: String?
}

struct AiConversationShare: Codable, Identifiable, Sendable {
    let id: String
    let conversationId: String
    let sharedByUserId: String
    let sharedWithUserId: String
    var permission: SharePermission
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case sharedByUserId = "shared_by_user_id"
        case sharedWithUserId = "shared_with_user_id"
        case permission
        case createdAt = "created_at"
    }
}

enum SharePermission: String, Codable, Sendable, CaseIterable {
    case read
    case write
}

extension ISO8601DateFormatter {
    /// Shared formatter that accepts the timestamp shape Supabase emits
    /// (with fractional seconds and either Z or ±HH:MM offsets).
    /// `ISO8601DateFormatter` is thread-safe per Apple docs, so the
    /// `nonisolated(unsafe)` annotation is correct under Swift 6 strict
    /// concurrency.
    nonisolated(unsafe) static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
