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
        return try await SupabasePaging.all("profiles") { count in
            supabase
                .from("profiles")
                .select(count: count)
                .in("id", values: ids)
        }
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

    /// Records the device's IANA time zone on the profile
    /// (`profiles.timezone`, migration 20261117130001) so the server knows
    /// the user's local calendar day: budget periods, "today" and the
    /// 80 % / 100 % pushes must use the day the phone shows. Fire-and-forget:
    /// skips the write when this user's zone is already synced, never
    /// throws (a failure retries on the next launch).
    func updateTimezoneIfNeeded(_ timeZone: TimeZone = .current) async {
        let identifier = timeZone.identifier
        do {
            let userId = try await SupabaseManager.shared.currentUserId()
            let syncedKey = "profile_timezone_synced.\(userId)"
            if UserDefaults.standard.string(forKey: syncedKey) == identifier { return }
            try await supabase
                .from("profiles")
                .update(["timezone": identifier])
                .eq("id", value: userId)
                .execute()
            UserDefaults.standard.set(identifier, forKey: syncedKey)
        } catch {
            AppLogger.data.debug("timezone sync skipped: \(error.localizedDescription)")
        }
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
