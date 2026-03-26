import Foundation
import Supabase

final class AchievementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Achievement] {
        try await supabase
            .from("achievements")
            .select()
            .order("sort_order")
            .execute()
            .value
    }

    func fetchUserAchievements() async throws -> [UserAchievement] {
        try await supabase
            .from("user_achievements")
            .select()
            .execute()
            .value
    }

    func markNotified(id: String) async throws {
        try await supabase
            .from("user_achievements")
            .update(["notified": true])
            .eq("id", value: id)
            .execute()
    }
}
