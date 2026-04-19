import Foundation
import Supabase

/// CRUD wrapper around the `deposits` table. RLS enforces own-only access
/// server-side, so reads don't need a client-side user-id filter.
///
/// Rate immutability is enforced on the client — `update(id:_)` deliberately
/// does NOT expose an `interest_rate` field. If a user needs a different
/// rate, create a new deposit and close the old one early.
final class DepositRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Deposit] {
        try await supabase
            .from("deposits")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchActive() async throws -> [Deposit] {
        try await supabase
            .from("deposits")
            .select()
            .eq("status", value: DepositStatus.active.rawValue)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Returns the deposit attached to a given account, or nil.
    /// Matches the 1:1 FK in the schema via `UNIQUE (account_id)`.
    func fetchForAccount(_ accountId: String) async throws -> Deposit? {
        let results: [Deposit] = try await supabase
            .from("deposits")
            .select()
            .eq("account_id", value: accountId)
            .limit(1)
            .execute()
            .value
        return results.first
    }

    func create(_ input: CreateDepositInput) async throws -> Deposit {
        try await supabase
            .from("deposits")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    /// Update a deposit. Note: `interest_rate`, `start_date`, and
    /// `compound_frequency` are intentionally NOT in `UpdateDepositInput` —
    /// those are immutable after creation.
    func update(id: String, _ input: UpdateDepositInput) async throws {
        try await supabase
            .from("deposits")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        // ON DELETE CASCADE on deposits.account_id would leave an orphan
        // account row — we delete the account instead, which cascades to
        // the deposit and its contributions via the FK chain.
        // Caller should delete the account; this method is a fallback for
        // edge cases (deposit row without account).
        try await supabase
            .from("deposits")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// Insert payload. `user_id` filled from `auth.uid()` server-side default.
struct CreateDepositInput: Encodable, Sendable {
    let user_id: String
    let account_id: String
    /// Sent as Decimal — PostgREST accepts either number or string for
    /// NUMERIC. Decimal keeps precision through JSON serialization.
    let interest_rate: Decimal
    let compound_frequency: String
    let start_date: String
    let end_date: String?
    let return_to_account_id: String?
    let notes: String?
}

/// Mutable-field update. `interest_rate` / `compound_frequency` /
/// `start_date` are deliberately omitted — immutable by contract.
struct UpdateDepositInput: Encodable, Sendable {
    let notes: String?
    let return_to_account_id: String?
    let early_close_penalty_rate: Decimal?
    let status: String?
    let closed_at: String?
    let end_date: String?
}
