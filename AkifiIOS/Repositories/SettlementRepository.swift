import Foundation
import Supabase

/// CRUD wrapper around the `settlements` table. All members of a shared
/// account can read and insert; only the creator (`settled_by`) can delete.
final class SettlementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Fetches all settlements recorded against a shared account, newest first.
    func fetchForAccount(_ accountId: String) async throws -> [Settlement] {
        try await supabase
            .from("settlements")
            .select()
            .eq("shared_account_id", value: accountId)
            .order("settled_at", ascending: false)
            .execute()
            .value
    }

    /// Inserts a new settlement and returns the server-assigned row. Client
    /// is expected to pre-fill `id` with a UUID (or leave empty — DB has a
    /// default) and `settledBy` with `auth.uid()`.
    func create(_ settlement: CreateSettlementInput) async throws -> Settlement {
        try await supabase
            .from("settlements")
            .insert(settlement)
            .select()
            .single()
            .execute()
            .value
    }

    func delete(id: String) async throws {
        try await supabase
            .from("settlements")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// Minimal DTO for creating a settlement. `id`, `settledAt`, `createdAt`
/// are filled server-side.
struct CreateSettlementInput: Encodable, Sendable {
    let shared_account_id: String
    let from_user_id: String
    let to_user_id: String
    let amount: Int64
    let currency: String
    let period_start: String
    let period_end: String
    let settled_by: String
    let linked_transfer_group_id: String?
    let note: String?
}
