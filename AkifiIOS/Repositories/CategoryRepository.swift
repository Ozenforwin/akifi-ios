import Foundation
import Supabase

final class CategoryRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Category] {
        try await supabase
            .from("categories")
            .select()
            .eq("is_active", value: true)
            .order("created_at")
            .execute()
            .value
    }

    func create(name: String, icon: String, color: String, type: CategoryType, accountId: String? = nil) async throws -> Category {
        struct Input: Encodable {
            let name: String
            let icon: String
            let color: String
            let type: String
            let account_id: String?
        }

        return try await supabase
            .from("categories")
            .insert(Input(name: name, icon: icon, color: color, type: type.rawValue, account_id: accountId))
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

    func transactionCount(categoryId: String) async throws -> Int {
        let result: [Transaction] = try await supabase
            .from("transactions")
            .select()
            .eq("category_id", value: categoryId)
            .execute()
            .value
        return result.count
    }
}
