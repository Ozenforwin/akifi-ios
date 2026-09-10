import Foundation
import Supabase

final class AchievementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Achievement] {
        try await SupabasePaging.all("achievements") { count in
            supabase
                .from("achievements")
                .select(count: count)
                .order("sort_order")
        }
    }

    func fetchUserAchievements() async throws -> [UserAchievement] {
        try await SupabasePaging.all("user_achievements") { count in
            supabase
                .from("user_achievements")
                .select(count: count)
        }
    }

    func markNotified(id: String) async throws {
        try await supabase
            .from("user_achievements")
            .update(["notified": true])
            .eq("id", value: id)
            .execute()
    }
}
