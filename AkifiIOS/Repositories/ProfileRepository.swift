import Foundation
import Supabase

final class ProfileRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetch() async throws -> Profile {
        let userId = try await SupabaseManager.shared.currentUserId()
        return try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
    }

    func fetchAll(ids: [String]) async throws -> [Profile] {
        guard !ids.isEmpty else { return [] }
        return try await supabase
            .from("profiles")
            .select()
            .in("id", values: ids)
            .execute()
            .value
    }

    func update(fullName: String?, avatarUrl: String?) async throws {
        var updates: [String: String] = [:]
        if let fullName { updates["full_name"] = fullName }
        if let avatarUrl { updates["avatar_url"] = avatarUrl }

        let userId = try await SupabaseManager.shared.currentUserId()
        try await supabase
            .from("profiles")
            .update(updates)
            .eq("id", value: userId)
            .execute()
    }

    /// Sync the user's UI language preference so backend notifications
    /// (weekly digest, smart notifications) render in the same language.
    /// Accepts "ru", "en", "es"; anything else becomes "ru".
    func updatePreferredLanguage(_ languageCode: String) async throws {
        let normalized: String = {
            let prefix = languageCode.lowercased().split(separator: "_").first.map(String.init) ?? languageCode.lowercased()
            return ["ru", "en", "es"].contains(prefix) ? prefix : "ru"
        }()
        let userId = try await SupabaseManager.shared.currentUserId()
        try await supabase
            .from("profiles")
            .update(["preferred_language": normalized])
            .eq("id", value: userId)
            .execute()
    }
}
