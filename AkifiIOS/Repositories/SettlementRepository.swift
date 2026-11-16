import Foundation
import Supabase

/// CRUD wrapper around the `settlements` table. All members of a shared
/// account can read and insert; only the creator (`settled_by`) can delete.
final class SettlementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Fetches all settlements recorded against a shared account, newest first.
    func fetchForAccount(_ accountId: String) async throws -> [Settlement] {
        try await SupabasePaging.all("settlements") { count in
            supabase
                .from("settlements")
                .select(count: count)
                .eq("shared_account_id", value: accountId)
                .order("settled_at", ascending: false)
        }
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

    /// Server-computed "who owes whom" (RPC `get_account_settlement`,
    /// migration 20261117090000). The server sees every row, so the result is
    /// identical for every member — unlike a client computation over the
    /// RLS-filtered transaction list, where each member can't see the other's
    /// personal cards.
    func fetchServerSettlement(_ accountId: String) async throws -> ServerSettlement {
        // bounded-fetch: the RPC returns one jsonb value, not a row set — max-rows cannot apply.
        try await supabase
            .rpc("get_account_settlement", params: ServerSettlementParams(p_account_id: accountId))
            .execute()
            .value
    }
}

private struct ServerSettlementParams: Encodable, Sendable {
    let p_account_id: String
}

/// Response of `get_account_settlement`. All amounts are kopecks in the
/// shared account's currency.
struct ServerSettlement: Decodable, Sendable, Equatable {
    struct Balance: Decodable, Sendable, Equatable {
        let userId: String
        let contributed: Int64
        let fairShare: Int64

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case contributed
            case fairShare = "fair_share"
        }
    }

    let version: Int
    let totalExpenses: Int64
    let balances: [Balance]
    /// Main expense transaction id → payer user id. The single payer
    /// attribution the per-transaction settle UI must use.
    let payers: [String: String]

    enum CodingKeys: String, CodingKey {
        case version
        case totalExpenses = "total_expenses"
        case balances
        case payers
    }

    var memberBalances: [SettlementCalculator.MemberBalance] {
        balances.map {
            SettlementCalculator.MemberBalance(
                userId: $0.userId.lowercased(),
                contributed: $0.contributed,
                fairShare: $0.fairShare
            )
        }
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
