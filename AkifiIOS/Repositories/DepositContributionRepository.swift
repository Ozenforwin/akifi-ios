import Foundation
import Supabase

/// CRUD wrapper around `deposit_contributions`. RLS is own-only.
///
/// Contributions are immutable once created (no update/edit path in MVP).
/// If the user mistyped, they delete the contribution (which cascades to
/// nothing else — the transfer pair must be deleted separately via the
/// transactions RPC) and recreate.
final class DepositContributionRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchForDeposit(_ depositId: String) async throws -> [DepositContribution] {
        try await supabase
            .from("deposit_contributions")
            .select()
            .eq("deposit_id", value: depositId)
            .order("contributed_at")
            .execute()
            .value
    }

    func fetchAll() async throws -> [DepositContribution] {
        try await supabase
            .from("deposit_contributions")
            .select()
            .order("contributed_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateDepositContributionInput) async throws -> DepositContribution {
        try await supabase
            .from("deposit_contributions")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func delete(id: String) async throws {
        try await supabase
            .from("deposit_contributions")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// Insert payload for a new contribution. All amounts are BIGINT kopecks.
struct CreateDepositContributionInput: Encodable, Sendable {
    let user_id: String
    let deposit_id: String
    /// Amount in the deposit's own currency (kopecks).
    let amount: Int64
    /// "yyyy-MM-dd"
    let contributed_at: String
    let source_account_id: String?
    let source_currency: String?
    /// Amount in `source_currency` (kopecks). Present only for
    /// cross-currency contributions.
    let source_amount: Int64?
    /// Snapshot of the FX rate at time of contribution. Decimal for
    /// NUMERIC(18,8) precision.
    let fx_rate: Decimal?
    /// UUID linking to the transfer pair in the `transactions` table.
    let transfer_group_id: String?
}
