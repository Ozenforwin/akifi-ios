import Foundation
import Supabase

final class CategoryRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Category] {
        try await SupabasePaging.all("categories") { count in
            supabase
                .from("categories")
                .select(count: count)
                .eq("is_active", value: true)
                .order("created_at")
        }
    }

    func fetchAllIncludingHidden() async throws -> [Category] {
        try await SupabasePaging.all("categories") { count in
            supabase
                .from("categories")
                .select(count: count)
                .order("is_active", ascending: false)
                .order("created_at")
        }
    }

    func toggleActive(id: String, isActive: Bool) async throws {
        try await supabase
            .from("categories")
            .update(["is_active": isActive])
            .eq("id", value: id)
            .execute()
    }

    func create(name: String, icon: String, color: String, type: CategoryType, accountId: String? = nil) async throws -> Category {
        struct Input: Encodable {
            let user_id: String
            let name: String
            let icon: String
            let color: String
            let type: String
            let account_id: String?
        }

        // RLS policy requires user_id = auth.uid().
        // Migration 60 also sets DEFAULT auth.uid() server-side.
        let userId = try await SupabaseManager.shared.currentUserId()

        return try await supabase
            .from("categories")
            .insert(Input(user_id: userId, name: name, icon: icon, color: color, type: type.rawValue, account_id: accountId))
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, name: String, icon: String, color: String) async throws -> Category {
        struct Input: Encodable {
            let name: String
            let icon: String
            let color: String
        }

        return try await supabase
            .from("categories")
            .update(Input(name: name, icon: icon, color: color))
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    func delete(id: String) async throws {
        try await supabase
            .from("categories")
            .update(["is_active": false])
            .eq("id", value: id)
            .execute()
    }

    /// Counts server-side. Fetching the rows to call `.count` on them both
    /// wasted the payload and capped the answer at PostgREST's `max-rows`
    /// (1000) — a busy category would silently report exactly 1000.
    func transactionCount(categoryId: String) async throws -> Int {
        let response = try await supabase
            .from("transactions")
            .select("id", head: true, count: .exact)
            .eq("category_id", value: categoryId)
            .execute()
        return response.count ?? 0
    }
}
