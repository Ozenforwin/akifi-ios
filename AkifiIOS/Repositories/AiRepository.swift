import Foundation
import Supabase
import Functions

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
        // RLS policy requires user_id = auth.uid().
        // Migration 60 also sets DEFAULT auth.uid() server-side.
        let userId = try await SupabaseManager.shared.currentUserId()
        return try await supabase
            .from("ai_conversations")
            .insert(["user_id": userId, "source": "ios"])
            .select()
            .single()
            .execute()
            .value
    }

    /// Returns the most recently updated non-archived conversation together
    /// with a one-line preview of its last assistant answer. Used by the
    /// "Continue last chat" card on the assistant welcome screen.
    /// Returns nil when there is no recent conversation or it is older
    /// than `maxAgeHours`.
    func fetchLastConversationPreview(maxAgeHours: Int = 24 * 7) async throws -> ConversationPreview? {
        let conversations: [AiConversation] = try await supabase
            .from("ai_conversations")
            .select()
            .eq("is_archived", value: false)
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        guard let conv = conversations.first else { return nil }

        if let updated = conv.updatedAt,
           let updatedDate = ISO8601DateFormatter.shared.date(from: updated),
           Date().timeIntervalSince(updatedDate) > Double(maxAgeHours) * 3600 {
            return nil
        }

        let messages: [AiMessage] = try await supabase
            .from("ai_messages")
            .select()
            .eq("conversation_id", value: conv.id)
            .eq("role", value: MessageRole.assistant.rawValue)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return ConversationPreview(conversation: conv, lastAnswer: messages.first?.content)
    }

    func archiveConversation(id: String) async throws {
        try await supabase
            .from("ai_conversations")
            .update(["is_archived": true])
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Sharing

    /// Lists shares for a conversation. RLS makes this readable for both
    /// the sharer and the recipient(s).
    func listShares(conversationId: String) async throws -> [AiConversationShare] {
        try await supabase
            .from("ai_conversation_shares")
            .select()
            .eq("conversation_id", value: conversationId)
            .execute()
            .value
    }

    /// Looks up another Akifi user by email (exact match) and returns their
    /// public profile id. Returns nil when no profile exists for the email.
    func findUserByEmail(_ email: String) async throws -> String? {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await supabase
            .from("profiles")
            .select("id")
            .eq("email", value: email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    /// Grants access. Requires the caller to own the conversation
    /// (enforced by the RLS INSERT policy).
    func shareConversation(
        conversationId: String,
        withUserId: String,
        permission: SharePermission
    ) async throws -> AiConversationShare {
        let userId = try await SupabaseManager.shared.currentUserId()
        struct Input: Encodable {
            let conversation_id: String
            let shared_by_user_id: String
            let shared_with_user_id: String
            let permission: String
        }
        return try await supabase
            .from("ai_conversation_shares")
            .insert(Input(
                conversation_id: conversationId,
                shared_by_user_id: userId,
                shared_with_user_id: withUserId,
                permission: permission.rawValue
            ))
            .select()
            .single()
            .execute()
            .value
    }

    /// Revokes access. Either the sharer or the recipient may revoke.
    func revokeShare(_ shareId: String) async throws {
        try await supabase
            .from("ai_conversation_shares")
            .delete()
            .eq("id", value: shareId)
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

    func sendMessage(
        conversationId: String?,
        content: String,
        context: AssistantContext? = nil,
        recentMessages: [[String: String]]? = nil
    ) async throws -> AssistantResponse {
        var body: [String: AnyJSON] = [
            "query": AnyJSON(stringLiteral: content),
            "source": AnyJSON(stringLiteral: "ios")
        ]
        if let conversationId {
            body["conversation_id"] = AnyJSON(stringLiteral: conversationId)
        }
        // Serialize complex objects as JSON strings — AnyJSON doesn't support nested dicts
        if let context {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(context),
               let jsonString = String(data: data, encoding: .utf8) {
                body["context_json"] = AnyJSON(stringLiteral: jsonString)
            }
        }
        if let recentMessages, !recentMessages.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: recentMessages),
               let jsonString = String(data: data, encoding: .utf8) {
                body["recent_messages_json"] = AnyJSON(stringLiteral: jsonString)
            }
        }
        return try await invokeWithAuthRetry("assistant-query", body: body)
    }

    /// Invoke an edge function with one-shot auth retry.
    ///
    /// If the first call fails with an authentication error (401 / expired JWT),
    /// refresh the Supabase session and try once more. Avoids the "Сессия истекла"
    /// alert for the common case of a stale access token after background suspension.
    ///
    /// Key fix: after refreshSession(), we explicitly read the fresh accessToken
    /// and pass it via FunctionInvokeOptions.headers to bypass the race condition
    /// where the SDK's internal Functions auth header hasn't been updated yet.
    private func invokeWithAuthRetry<T: Decodable>(
        _ name: String,
        body: [String: AnyJSON]
    ) async throws -> T {
        // Proactively refresh the session before calling the edge function.
        // This prevents 401s caused by stale tokens after background suspension.
        let freshOptions = await freshInvokeOptions(body: body)

        do {
            return try await supabase.functions.invoke(name, options: freshOptions)
        } catch {
            guard isAuthFailure(error) else { throw error }
            AppLogger.ai.warning("Edge function \(name) hit auth failure — refreshing and retrying")

            // Force-refresh the session and get a guaranteed fresh token.
            let retryOptions = await refreshAndBuildOptions(body: body)
            return try await supabase.functions.invoke(name, options: retryOptions)
        }
    }

    /// Build FunctionInvokeOptions with an explicit Authorization header
    /// from the current session, bypassing the SDK's potentially stale internal state.
    ///
    /// Crucially, waits for any in-flight session refresh (e.g. one started by
    /// scenePhase.active) so we don't read a stale access token while a refresh
    /// is racing. Without this, the user hits 401 → retry → race with the
    /// ongoing refresh → `refresh_token_already_used` → misclassified as
    /// "session expired".
    private func freshInvokeOptions(body: [String: AnyJSON]) async -> FunctionInvokeOptions {
        do {
            let session = try await SupabaseManager.shared.currentSession()
            let token = session.accessToken
            AppLogger.ai.debug("Using access token expiring at \(session.expiresAt)")
            return .init(headers: ["Authorization": "Bearer \(token)"], body: body)
        } catch {
            AppLogger.ai.warning("Could not read session for fresh token: \(error.localizedDescription)")
            // Fall back to SDK's internal auth header
            return .init(body: body)
        }
    }

    /// Refresh the session through the coordinator (dedups concurrent callers),
    /// then build options with the new token.
    private func refreshAndBuildOptions(body: [String: AnyJSON]) async -> FunctionInvokeOptions {
        do {
            try await SupabaseManager.shared.refreshSession(force: true)
            let session = try await SupabaseManager.shared.currentSession()
            let token = session.accessToken
            AppLogger.ai.info("Refreshed session OK, new token expires at \(session.expiresAt)")
            return .init(headers: ["Authorization": "Bearer \(token)"], body: body)
        } catch {
            AppLogger.ai.error("refreshSession() failed: \(error.localizedDescription)")
            // Last resort: try with whatever the SDK has internally
            return .init(body: body)
        }
    }

    private func isAuthFailure(_ error: Error) -> Bool {
        if case FunctionsError.httpError(code: 401, data: _) = error { return true }
        if case FunctionsError.httpError(code: 403, data: _) = error { return true }
        let description = "\(error)".lowercased()
        return description.contains("401")
            || description.contains("jwt")
            || description.contains("unauthorized")
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

        let session = try await SupabaseManager.shared.currentSession()
        let url = URL(string: "\(AppConstants.supabaseURL)/functions/v1/transcribe-voice")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConstants.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: responseData.prefix(500), encoding: .utf8) ?? "(binary)"

        struct TranscribeResponse: Decodable {
            let ok: Bool?
            let text: String?
            let error: String?
        }

        if let result = try? JSONDecoder().decode(TranscribeResponse.self, from: responseData) {
            if result.ok == true, let text = result.text, !text.isEmpty {
                return text
            }
            let serverError = result.error ?? "Сервер (\(statusCode)): \(rawBody)"
            throw NSError(domain: "transcribe", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: serverError])
        }

        throw NSError(domain: "transcribe", code: statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode): \(rawBody)"])
    }

    // MARK: - Feedback

    func submitFeedback(requestId: String, score: Int, reason: String?) async throws {
        // RLS policy requires user_id = auth.uid().
        // Migration 60 also sets DEFAULT auth.uid() server-side.
        let userId = try await SupabaseManager.shared.currentUserId()
        var data: [String: AnyJSON] = [
            "user_id": AnyJSON(stringLiteral: userId),
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
        let userId = try await SupabaseManager.shared.currentUserId()
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
            // RLS policy requires user_id = auth.uid().
            // Migration 60 also sets DEFAULT auth.uid() server-side.
            let userId = try await SupabaseManager.shared.currentUserId()
            var data: [String: AnyJSON] = [
                "user_id": AnyJSON(stringLiteral: userId),
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
