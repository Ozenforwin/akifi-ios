import Foundation
import Supabase

final class AiRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Conversations

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

    func archiveConversation(id: String) async throws {
        try await supabase
            .from("ai_conversations")
            .update(["is_archived": true])
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Messages

    func fetchMessages(conversationId: String) async throws -> [AiMessage] {
        try await supabase
            .from("ai_messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .order("created_at")
            .execute()
            .value
    }

    // MARK: - Send Message (Edge Function)

    func sendMessage(conversationId: String?, content: String) async throws -> AssistantResponse {
        var body: [String: AnyJSON] = [
            "query": AnyJSON(stringLiteral: content),
            "source": AnyJSON(stringLiteral: "ios")
        ]
        if let conversationId {
            body["conversation_id"] = AnyJSON(stringLiteral: conversationId)
        }
        return try await supabase.functions.invoke(
            "assistant-query",
            options: .init(body: body)
        )
    }

    // MARK: - Action Preview & Execute

    func previewAction(
        conversationId: String,
        messageId: String,
        action: AssistantAction
    ) async throws -> ActionResponse {
        try await supabase.functions.invoke(
            "assistant-action",
            options: .init(body: [
                "conversation_id": conversationId,
                "message_id": messageId,
                "action_type": action.type.rawValue,
                "mode": "preview",
                "source": "ios"
            ])
        )
    }

    func confirmAction(
        conversationId: String,
        messageId: String,
        actionRunId: String,
        action: AssistantAction
    ) async throws -> ActionResponse {
        try await supabase.functions.invoke(
            "assistant-action",
            options: .init(body: [
                "conversation_id": conversationId,
                "message_id": messageId,
                "action_run_id": actionRunId,
                "action_type": action.type.rawValue,
                "mode": "confirm",
                "source": "ios"
            ])
        )
    }

    // MARK: - Voice Transcription

    func transcribeAudio(data: Data, mimeType: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()

        // Build multipart form data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let session = try await supabase.auth.session
        let url = URL(string: "\(AppConstants.supabaseURL)/functions/v1/transcribe-voice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConstants.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        // Try to parse response regardless of status code
        struct TranscribeResponse: Decodable {
            let ok: Bool?
            let text: String?
            let error: String?
        }

        if let result = try? JSONDecoder().decode(TranscribeResponse.self, from: responseData) {
            if result.ok == true, let text = result.text, !text.isEmpty {
                return text
            }
            // Server returned an error message
            let serverError = result.error ?? result.text ?? "Неизвестная ошибка"
            throw NSError(domain: "transcribe", code: httpResponse?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: serverError])
        }

        // Non-JSON response
        let bodyStr = String(data: responseData.prefix(200), encoding: .utf8) ?? "empty"
        throw NSError(domain: "transcribe", code: httpResponse?.statusCode ?? -1,
                      userInfo: [NSLocalizedDescriptionKey: "Сервер: \(httpResponse?.statusCode ?? 0) — \(bodyStr)"])
    }

    // MARK: - Feedback

    func submitFeedback(requestId: String, score: Int, reason: String?) async throws {
        var data: [String: AnyJSON] = [
            "request_id": AnyJSON(stringLiteral: requestId),
            "score": AnyJSON(integerLiteral: score)
        ]
        if let reason {
            data["reason"] = AnyJSON(stringLiteral: reason)
        }
        try await supabase
            .from("ai_feedback")
            .insert(data)
            .execute()
    }

    // MARK: - AI User Settings

    func fetchSettings() async throws -> AIUserSettings? {
        let response: [AIUserSettings] = try await supabase
            .from("ai_user_settings")
            .select()
            .limit(1)
            .execute()
            .value
        return response.first
    }

    func upsertSettings(_ settings: AIUserSettings) async throws {
        let userId = try await supabase.auth.session.user.id.uuidString
        var data: [String: AnyJSON] = [
            "user_id": AnyJSON(stringLiteral: userId),
            "tone": AnyJSON(stringLiteral: settings.tone.rawValue),
            "digest_opt_in": AnyJSON(booleanLiteral: settings.digestOptIn),
            "timezone": AnyJSON(stringLiteral: settings.timezone ?? TimeZone.current.identifier)
        ]
        if let start = settings.quietHoursStart {
            data["quiet_hours_start"] = AnyJSON(integerLiteral: start)
        }
        if let end = settings.quietHoursEnd {
            data["quiet_hours_end"] = AnyJSON(integerLiteral: end)
        }
        try await supabase
            .from("ai_user_settings")
            .upsert(data)
            .execute()
    }

    // MARK: - Analytics Events

    func logAnalyticsEvent(event: String, metadata: [String: String]? = nil) async {
        do {
            var data: [String: AnyJSON] = [
                "event": AnyJSON(stringLiteral: event),
                "source": AnyJSON(stringLiteral: "ios")
            ]
            if let metadata {
                for (key, value) in metadata {
                    data[key] = AnyJSON(stringLiteral: value)
                }
            }
            try await supabase
                .from("ai_analytics_events")
                .insert(data)
                .execute()
        } catch {
            // Analytics are non-critical — fail silently
        }
    }
}
