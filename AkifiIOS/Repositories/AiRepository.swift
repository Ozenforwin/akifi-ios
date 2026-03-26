import Foundation
import Supabase

final class AiRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchConversations() async throws -> [AiConversation] {
        try await supabase
            .from("ai_conversations")
            .select()
            .eq("is_archived", value: false)
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    func createConversation() async throws -> AiConversation {
        try await supabase
            .from("ai_conversations")
            .insert(["source": "ios"])
            .select()
            .single()
            .execute()
            .value
    }

    func fetchMessages(conversationId: String) async throws -> [AiMessage] {
        try await supabase
            .from("ai_messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .order("created_at")
            .execute()
            .value
    }

    func sendMessage(conversationId: String, content: String) async throws -> AssistantResponse {
        try await supabase.functions.invoke(
            "assistant-query",
            options: .init(body: [
                "conversation_id": conversationId,
                "message": content,
                "source": "ios"
            ])
        )
    }

    func archiveConversation(id: String) async throws {
        try await supabase
            .from("ai_conversations")
            .update(["is_archived": true])
            .eq("id", value: id)
            .execute()
    }
}

struct AssistantResponse: Codable, Sendable {
    let reply: String
    let intent: String?
    let followUps: [String]?

    enum CodingKeys: String, CodingKey {
        case reply, intent
        case followUps = "follow_ups"
    }
}
