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
}
