import Foundation
import Supabase

/// CRUD for `transaction_member_settlements`. Read-by-account fetches every
/// per-member mark across all txns of a shared account in one round-trip —
/// the calculator then groups by `transaction_id` to figure out which shares
/// of which txns are closed.
final class TransactionMemberSettlementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchForAccount(_ accountId: String) async throws -> [TransactionMemberSettlement] {
        try await supabase
            .from("transaction_member_settlements")
            .select()
            .eq("shared_account_id", value: accountId)
            .execute()
            .value
    }

    func create(_ input: CreateTransactionMemberSettlementInput) async throws -> TransactionMemberSettlement {
        try await supabase
            .from("transaction_member_settlements")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    /// Deletes a single mark by id. The RLS policy ensures only the marker
    /// can delete — non-marker callers will get an empty result, never an
    /// error, so we treat a no-op delete as success.
    func delete(id: String) async throws {
        try await supabase
            .from("transaction_member_settlements")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    /// Convenience: delete by composite key. Avoids a round-trip to look up
    /// the id when the caller already knows the (txn, member) pair.
    func delete(transactionId: String, settledForUserId: String) async throws {
        try await supabase
            .from("transaction_member_settlements")
            .delete()
            .eq("transaction_id", value: transactionId)
            .eq("settled_for_user_id", value: settledForUserId)
            .execute()
    }
}
