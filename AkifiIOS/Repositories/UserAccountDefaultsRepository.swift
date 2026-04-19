import Foundation
import Supabase

/// CRUD wrapper around the `user_account_defaults` table. Rows are
/// per-user (RLS guarantees this), so all reads are scoped to `auth.uid()`
/// by the server policy — no need to filter client-side.
final class UserAccountDefaultsRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Returns every default the current user has configured. Cheap — the
    /// table typically has ≤ N rows where N = number of shared accounts.
    func fetchAll() async throws -> [UserAccountDefault] {
        try await supabase
            .from("user_account_defaults")
            .select()
            .execute()
            .value
    }

    /// Returns the default for a single target account, or `nil` if unset.
    func fetchFor(accountId: String) async throws -> UserAccountDefault? {
        let rows: [UserAccountDefault] = try await supabase
            .from("user_account_defaults")
            .select()
            .eq("account_id", value: accountId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Inserts or updates the default source for a given target account.
    /// Uses the PK `(user_id, account_id)` for conflict resolution.
    func upsert(accountId: String, defaultSourceId: String?) async throws {
        struct Payload: Encodable {
            let user_id: String
            let account_id: String
            let default_source_id: String?
        }
        let userId = try await SupabaseManager.shared.currentUserId()
        let payload = Payload(
            user_id: userId,
            account_id: accountId,
            default_source_id: defaultSourceId
        )
        try await supabase
            .from("user_account_defaults")
            .upsert(payload, onConflict: "user_id,account_id")
            .execute()
    }

    func delete(accountId: String) async throws {
        try await supabase
            .from("user_account_defaults")
            .delete()
            .eq("account_id", value: accountId)
            .execute()
    }
}
