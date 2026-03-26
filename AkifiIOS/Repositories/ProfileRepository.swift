import Foundation
import Supabase

final class ProfileRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetch() async throws -> Profile {
        try await supabase
            .from("profiles")
            .select()
            .single()
            .execute()
            .value
    }

    func update(fullName: String?, avatarUrl: String?) async throws {
        var updates: [String: String] = [:]
        if let fullName { updates["full_name"] = fullName }
        if let avatarUrl { updates["avatar_url"] = avatarUrl }

        try await supabase
            .from("profiles")
            .update(updates)
            .eq("id", value: try await supabase.auth.session.user.id.uuidString)
            .execute()
    }
}
