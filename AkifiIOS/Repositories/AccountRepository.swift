import Foundation
import Supabase

final class AccountRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Account] {
        try await supabase
            .from("accounts")
            .select()
            .order("created_at")
            .execute()
            .value
    }

    func create(name: String, icon: String, color: String, initialBalance: Int64) async throws -> Account {
        struct CreateInput: Encodable {
            let name: String
            let icon: String
            let color: String
            let initial_balance: Int64
        }

        return try await supabase
            .from("accounts")
            .insert(CreateInput(name: name, icon: icon, color: color, initial_balance: initialBalance))
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, name: String, icon: String, color: String) async throws {
        struct UpdateInput: Encodable {
            let name: String
            let icon: String
            let color: String
        }

        try await supabase
            .from("accounts")
            .update(UpdateInput(name: name, icon: icon, color: color))
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("accounts")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}
